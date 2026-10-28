import Foundation
import Combine

enum TagMediaAvailabilityState: Equatable {
    case enough
    case sparse
    case unknown
}

struct TagMediaAvailabilityResult: Equatable {
    let state: TagMediaAvailabilityState
    let countLowerBound: Int
    let exhausted: Bool
    let checkedAt: Date
}

/// Bounded metadata-only availability probe for tag directory rows.
@MainActor final class TagMediaAvailability: ObservableObject {
    static let shared = TagMediaAvailability()
    @Published private(set) var revision = 0
    private struct Key: Hashable { let identity: String; let tagID: Int }
    private struct Entry { let result: TagMediaAvailabilityResult; let expiresAt: Date; var touched: UInt64 }
    private var entries: [Key: Entry] = [:]
    private var tick: UInt64 = 0
    private var batchActive = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private let now: () -> Date
    private let maxEntries: Int
    private let maxTagsPerBatch: Int
    private let maxConcurrency: Int
    private let limit = 3
    private let maxPages = 3

    init(maxEntries: Int = 256, maxTagsPerBatch: Int = 12, maxConcurrency: Int = 2, now: @escaping () -> Date = Date.init) {
        self.maxEntries = min(256, max(1, maxEntries)); self.maxTagsPerBatch = min(12, max(1, maxTagsPerBatch))
        self.maxConcurrency = min(2, max(1, maxConcurrency)); self.now = now
    }

    func result(tagID: Int, identity: String) -> TagMediaAvailabilityResult? {
        let key = Key(identity: identity, tagID: tagID)
        guard let entry = entries[key], entry.expiresAt > now() else { entries.removeValue(forKey: key); return nil }
        tick &+= 1; entries[key]?.touched = tick
        return entry.result
    }
    func isSparse(tagID: Int, identity: String) -> Bool { result(tagID: tagID, identity: identity)?.state == .sparse }
    func checkedCount(identity: String) -> Int { Array(entries.keys).filter { $0.identity == identity && result(tagID: $0.tagID, identity: identity) != nil }.count }

    /// Callers wait for the admitted batch and recheck its cache afterwards.
    /// A cancelled owner can therefore be replaced even for identical IDs,
    /// without temporarily doubling the network concurrency.
    func verify(tags: [SearchTag], source: any TagCandidateSource) async {
        let identity = source.feedIdentity
        var seen = Set<Int>()
        let ids = tags.map(\.id).filter { $0 > 0 && seen.insert($0).inserted }
        func pending() -> [Int] { Array(ids.filter { result(tagID: $0, identity: identity) == nil }.prefix(maxTagsPerBatch)) }
        while batchActive {
            guard !Task.isCancelled, identity == source.feedIdentity else { return }
            guard waiters.count < 16 else { return }
            await waitForBatch()
        }
        guard !Task.isCancelled, identity == source.feedIdentity else { return }
        let candidates = pending()
        guard !candidates.isEmpty else { return }
        batchActive = true
        defer {
            batchActive = false
            let completed = Array(waiters.values); waiters.removeAll()
            completed.forEach { $0.resume() }
        }
        let workLimit = maxConcurrency
        await withTaskGroup(of: (Int, TagMediaAvailabilityResult).self) { group in
            var next = 0
            func add(_ id: Int) { group.addTask {
                return (id, await self.probe(tagID: id, identity: identity, source: source))
            } }
            while next < min(workLimit, candidates.count) { add(candidates[next]); next += 1 }
            while let (id, value) = await group.next() {
                guard !Task.isCancelled, source.feedIdentity == identity else { group.cancelAll(); return }
                put(value, tagID: id, identity: identity)
                if next < candidates.count { add(candidates[next]); next += 1 }
            }
        }
        if source.feedIdentity == identity { revision &+= 1 }
    }

    private func waitForBatch() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || !batchActive { continuation.resume() }
                else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor in self.waiters.removeValue(forKey: id)?.resume() }
        }
    }

    private func probe(tagID: Int, identity: String, source: any TagCandidateSource) async -> TagMediaAvailabilityResult {
        var cursor: String?; var seenCursors = Set<String>(); var seenIDs = Set<Int>()
        var pages = 0; var exhausted = false
        func result(_ state: TagMediaAvailabilityState) -> TagMediaAvailabilityResult {
            .init(state: state, countLowerBound: seenIDs.count, exhausted: exhausted, checkedAt: now())
        }
        do {
            while pages < maxPages {
                try Task.checkCancellation()
                guard identity == source.feedIdentity else { return result(.unknown) }
                let page = try await source.tagCandidates(tagID: tagID, author: nil,
                    filter: FeedFilter(kind: .all, sort: "Newest", period: "AllTime", baseModel: "", onlyPG: false, videoDurationRange: nil),
                    cursor: cursor, limit: limit)
                try Task.checkCancellation()
                guard identity == source.feedIdentity, page.items.count <= limit else { return result(.unknown) }
                pages += 1
                var pageIDs = Set<Int>()
                for item in page.items {
                    guard item.id > 0, item.type == "image" || item.type == "video",
                          item.tags?.contains(where: { $0.id == tagID }) == true else { return result(.unknown) }
                    pageIDs.insert(item.id)
                }
                if !pageIDs.isEmpty && pageIDs.isSubset(of: seenIDs) { return result(.unknown) }
                seenIDs.formUnion(pageIDs)
                if seenIDs.count >= limit { return result(.enough) }
                guard let next = page.metadata.nextCursor else { exhausted = true; return result(.sparse) }
                guard !next.isEmpty, next != cursor, seenCursors.insert(next).inserted else { return result(.unknown) }
                cursor = next
            }
            return result(.unknown)
        } catch { return result(.unknown) }
    }

    private func put(_ value: TagMediaAvailabilityResult, tagID: Int, identity: String) {
        guard identity.isEmpty == false else { return }
        tick &+= 1
        let ttl: TimeInterval = switch value.state { case .sparse: 600; case .enough: 3600; case .unknown: 30 }
        entries[Key(identity: identity, tagID: tagID)] = Entry(result: value, expiresAt: now().addingTimeInterval(ttl), touched: tick)
        while entries.count > maxEntries, let oldest = entries.min(by: { $0.value.touched < $1.value.touched })?.key { entries.removeValue(forKey: oldest) }
        revision &+= 1
    }
}
