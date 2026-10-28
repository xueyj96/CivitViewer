import Foundation
import Combine

enum TagMediaAvailabilityState: Equatable { case enough, sparse, unknown }

enum TagMediaAvailabilityReason: String {
    case thresholdReached, exhausted, pageLimit, requestFailed, http, tagMismatch, invalidMedia
    case repeatedPage, repeatedCursor, metadataMissing, contextChanged, cancelled, searchEmpty, authUnavailable
}

struct TagAvailabilityPolicy: Hashable {
    var blockedTags: Set<String> = []
    var blockedAuthorIDs: Set<Int> = []
    var blockedAuthorHandles: Set<String> = []
    var deduplicateMediaAssets: Bool = true

    var normalizedBlockedTags: Set<String> { Set(blockedTags.map(TagPolicy.normalize)) }
    var normalizedBlockedAuthorHandles: Set<String> { Set(blockedAuthorHandles.map(AuthorHandlePolicy.normalize)) }
}

struct TagMediaAvailabilityResult: Equatable {
    let state: TagMediaAvailabilityState
    let countLowerBound: Int
    let exhausted: Bool
    let checkedAt: Date
    let reason: TagMediaAvailabilityReason
    let httpStatus: Int?
    let pages: Int
    let rawCount: Int
    let hasMore: Bool
}

/// Bounded metadata-only availability probe for tag directory rows.
@MainActor final class TagMediaAvailability: ObservableObject {
    static let shared = TagMediaAvailability(diagnostics: .shared)
    @Published private(set) var revision = 0
    private struct Key: Hashable { let identity: String; let tagID: Int; let policy: TagAvailabilityPolicy }
    private struct Entry { let result: TagMediaAvailabilityResult; let expiresAt: Date; var touched: UInt64 }
    private var entries: [Key: Entry] = [:]
    private var tick: UInt64 = 0
    private var batchActive = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private let now: () -> Date
    private let maxEntries: Int
    private let maxTagsPerBatch: Int
    private let maxConcurrency: Int
    private let minimumVisible = 3
    private let requestLimit = 20
    private let maxPages = 3
    private let diagnostics: LocalDiagnosticsStore?

    init(maxEntries: Int = 256, maxTagsPerBatch: Int = 12, maxConcurrency: Int = 2, now: @escaping () -> Date = Date.init,
         diagnostics: LocalDiagnosticsStore? = nil) {
        self.maxEntries = min(256, max(1, maxEntries)); self.maxTagsPerBatch = min(12, max(1, maxTagsPerBatch))
        self.maxConcurrency = min(2, max(1, maxConcurrency)); self.now = now
        self.diagnostics = diagnostics
    }

    func result(tagID: Int, identity: String, policy: TagAvailabilityPolicy = .init()) -> TagMediaAvailabilityResult? {
        let key = Key(identity: identity, tagID: tagID, policy: policy)
        guard let entry = entries[key], entry.expiresAt > now() else { entries.removeValue(forKey: key); return nil }
        tick &+= 1; entries[key]?.touched = tick
        return entry.result
    }
    func isSparse(tagID: Int, identity: String, policy: TagAvailabilityPolicy = .init()) -> Bool { result(tagID: tagID, identity: identity, policy: policy)?.state == .sparse }
    func isRecommended(tagID: Int, identity: String, policy: TagAvailabilityPolicy = .init()) -> Bool { result(tagID: tagID, identity: identity, policy: policy)?.state == .enough }
    func recordEmptySearch(tagID: Int, identity: String, policy: TagAvailabilityPolicy) {
        guard result(tagID: tagID, identity: identity, policy: policy)?.state == .enough else { return }
        put(.init(state: .unknown, countLowerBound: 0, exhausted: true, checkedAt: now(), reason: .searchEmpty,
                  httpStatus: nil, pages: 1, rawCount: 0, hasMore: false), tagID: tagID, identity: identity, policy: policy)
    }
    func checkedCount(identity: String) -> Int {
        let keys = entries.keys.filter { $0.identity == identity }
        return keys.filter { result(tagID: $0.tagID, identity: identity, policy: $0.policy) != nil }.count
    }

    /// Callers wait for the admitted batch and recheck its cache afterwards.
    /// A cancelled owner can therefore be replaced even for identical IDs,
    /// without temporarily doubling the network concurrency.
    func verify(tags: [SearchTag], source: any TagCandidateSource, policy: TagAvailabilityPolicy = .init()) async {
        let identity = source.feedIdentity
        var seen = Set<Int>()
        let ids = tags.map(\.id).filter { $0 > 0 && seen.insert($0).inserted }
        func pending() -> [Int] { Array(ids.filter { result(tagID: $0, identity: identity, policy: policy) == nil }.prefix(maxTagsPerBatch)) }
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
        await withTaskGroup(of: (Int, TagMediaAvailabilityResult).self) { group in
            var next = 0
            func add(_ id: Int) { group.addTask {
                return (id, await self.probe(tagID: id, identity: identity, source: source, policy: policy))
            } }
            while next < min(maxConcurrency, candidates.count) { add(candidates[next]); next += 1 }
            while let (id, value) = await group.next() {
                guard !Task.isCancelled, source.feedIdentity == identity else { group.cancelAll(); return }
                put(value, tagID: id, identity: identity, policy: policy)
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

    private func probe(tagID: Int, identity: String, source: any TagCandidateSource, policy: TagAvailabilityPolicy) async -> TagMediaAvailabilityResult {
        var cursor: String?; var seenCursors = Set<String>(); var seenPageIDs = Set<String>(); var seenSourceIDs = Set<Int>()
        var pages = 0; var rawCount = 0; var exhausted = false; var hasMore = false
        var uncertainMetadata = false
        var invalidMedia = false
        let normalizedTags = policy.normalizedBlockedTags
        var accumulator = FeedAccumulator(blockedTags: normalizedTags, deduplicateMediaAssets: policy.deduplicateMediaAssets)
        accumulator.applyBlockedAuthors(ids: policy.blockedAuthorIDs, handles: policy.normalizedBlockedAuthorHandles)
        func result(_ state: TagMediaAvailabilityState, _ reason: TagMediaAvailabilityReason, httpStatus: Int? = nil) -> TagMediaAvailabilityResult {
            .init(state: state, countLowerBound: accumulator.items.count, exhausted: exhausted, checkedAt: now(), reason: reason,
                  httpStatus: httpStatus, pages: pages, rawCount: rawCount, hasMore: hasMore)
        }
        guard tagID > 0 else { return result(.unknown, .tagMismatch) }
        do {
            while pages < maxPages {
                try Task.checkCancellation()
                guard identity == source.feedIdentity else { return result(.unknown, .contextChanged) }
                let page = try await source.tagCandidates(tagID: tagID, author: nil,
                    filter: FeedFilter(kind: .all, sort: "Newest", period: "AllTime", baseModel: "", onlyPG: false, videoDurationRange: nil),
                    cursor: cursor, limit: requestLimit)
                try Task.checkCancellation()
                guard identity == source.feedIdentity else { return result(.unknown, .contextChanged) }
                guard page.items.count <= requestLimit else { return result(.unknown, .invalidMedia) }
                pages += 1; rawCount += page.items.count
                hasMore = page.metadata.nextCursor != nil
                var pageIDs = Set<Int>()
                for item in page.items {
                    guard item.id > 0 else { return result(.unknown, .invalidMedia) }
                    guard let tags = item.tags, !tags.isEmpty else { return result(.unknown, .metadataMissing) }
                    guard tags.contains(where: { $0.id == tagID }) else { return result(.unknown, .tagMismatch) }
                    if !item.isSupported { invalidMedia = true }
                    if item.mediaURL == nil || (!normalizedTags.isEmpty && item.tagNames == nil) { uncertainMetadata = true }
                    pageIDs.insert(item.id)
                }
                let pageSignature = page.items.map { String($0.id) }.joined(separator: ",")
                if !page.items.isEmpty && !seenPageIDs.insert(pageSignature).inserted { return result(.unknown, .repeatedPage) }
                if !pageIDs.isEmpty && pageIDs.isSubset(of: seenSourceIDs) { return result(.unknown, .repeatedPage) }
                seenSourceIDs.formUnion(pageIDs)
                accumulator.append(page, kind: .all)
                if accumulator.items.count >= minimumVisible { return result(.enough, .thresholdReached) }
                guard let next = page.metadata.nextCursor else {
                    exhausted = true; hasMore = false
                    if uncertainMetadata { return result(.unknown, .metadataMissing) }
                    if invalidMedia { return result(.unknown, .invalidMedia) }
                    return result(.sparse, .exhausted)
                }
                guard !next.isEmpty, next != cursor, seenCursors.insert(next).inserted else { return result(.unknown, .repeatedCursor) }
                cursor = next
            }
            return result(.unknown, .pageLimit)
        } catch is CancellationError { return result(.unknown, .cancelled) }
        catch ClientError.signedOut { return result(.unknown, .authUnavailable, httpStatus: 401) }
        catch ClientError.http(let status) { return result(.unknown, .http, httpStatus: status) }
        catch { return result(.unknown, .requestFailed) }
    }

    private func put(_ value: TagMediaAvailabilityResult, tagID: Int, identity: String, policy: TagAvailabilityPolicy) {
        guard identity.isEmpty == false else { return }
        tick &+= 1
        let ttl: TimeInterval
        if value.reason == .searchEmpty { ttl = 600 }
        else { ttl = switch value.state { case .sparse: 600; case .enough: 3600; case .unknown: 30 } }
        entries[Key(identity: identity, tagID: tagID, policy: policy)] = Entry(result: value, expiresAt: now().addingTimeInterval(ttl), touched: tick)
        while entries.count > maxEntries, let oldest = entries.min(by: { $0.value.touched < $1.value.touched })?.key { entries.removeValue(forKey: oldest) }
        revision &+= 1
        let context = TagSearchDiagnostic(stage: "availability", tagIDs: [tagID], outcome: String(describing: value.state),
            reason: value.reason.rawValue, rawCount: value.rawCount, visibleCount: value.state == .unknown ? nil : value.countLowerBound,
            pages: value.pages, hasMore: value.hasMore, browsingLevel: nil, kind: "all", period: "AllTime", hasAuthor: false, hasText: false,
            blockedTags: policy.blockedTags.count, blockedAuthors: policy.blockedAuthorIDs.count)
        diagnostics?.note(area: .search, code: .tagProbe, httpStatus: value.httpStatus, tagSearch: context)
    }
}
