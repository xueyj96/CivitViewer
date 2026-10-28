import Foundation
import Combine
import CryptoKit

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

struct TagObservationEstimate: Equatable {
    let countLowerBound: Int
    let lastSeen: Date?
    let emptyUntil: Date?
    var isRecommended: Bool { countLowerBound >= 3 && emptyUntil == nil }
}

/// Local bounded evidence gathered only from items already admitted to a visible feed.
/// This is a lower bound over recent examples, never a total-count estimate.
@MainActor final class TagObservationStore: ObservableObject {
    static let shared: TagObservationStore = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return TagObservationStore(rootURL: base.appendingPathComponent("CivitTagLibrary/Observed", isDirectory: true))
    }()

    @Published private(set) var revision = 0

    private struct Witness: Codable, Equatable {
        let key: String
        let seenAt: Date
    }
    private struct TagRecord: Codable {
        var witnesses: [Witness]
        var emptyUntil: Date?
        var touchedAt: Date
    }
    private struct DiskTag: Codable {
        let tagID: Int
        let record: TagRecord
    }
    private struct DiskContext: Codable {
        let hash: String
        let touchedAt: Date
        let tags: [DiskTag]
    }
    private struct DiskFile: Codable {
        let version: Int
        var contexts: [DiskContext]
    }
    private struct Key: Hashable { let context: String; let tagID: Int }
    private enum LoadedFile { case missing, data(Data), invalid }

    private let rootURL: URL?
    private let now: () -> Date
    private let maxWitnesses = 8
    private let maxTagsPerContext = 5_000
    private let maxContexts = 4
    private let fileName = "observations-v1.json"
    private var records: [Key: TagRecord] = [:]
    private var contextTouches: [String: Date] = [:]
    private var loadTask: Task<LoadedFile, Never>?
    private var loaded = false
    private var persistenceWritable = true
    private var debounceTask: Task<Void, Never>?
    private var pendingWrite: (id: UUID, task: Task<(Int, Bool), Never>)?
    private var persistedRevision = 0

    init(rootURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.rootURL = rootURL
        self.now = now
        self.loaded = rootURL == nil
    }

    func activate(scope: String) async {
        guard let rootURL, !loaded else { return }
        if loadTask == nil {
            let fileURL = rootURL.appendingPathComponent(fileName)
            loadTask = Task.detached(priority: .utility) {
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                    guard let size = attributes[.size] as? NSNumber, size.uint64Value <= 8 * 1024 * 1024 else { return .invalid }
                    return .data(try Data(contentsOf: fileURL))
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return .missing }
                catch { return .invalid }
            }
        }
        guard let task = loadTask else { return }
        let loadedFile = await task.value
        guard !loaded else { loadTask = nil; return }
        loadTask = nil
        switch loadedFile {
        case .invalid:
            persistenceWritable = false
        case .missing:
            break
        case .data(let data):
            do {
                let file = try JSONDecoder().decode(DiskFile.self, from: data)
                guard file.version == 1,
                      isValid(file) else {
                    persistenceWritable = false
                    loaded = true
                    return
                }
                merge(file)
            } catch {
                // Preserve a corrupt or incompatible file; it is not evidence of zero.
                persistenceWritable = false
            }
        }
        loaded = true
        trim()
        revision &+= 1
        scheduleWriteIfNeeded()
    }

    func observe(items: [MediaItem], scope: String, policy: TagAvailabilityPolicy) {
        let context = contextHash(scope: scope, policy: policy)
        let stamp = now()
        contextTouches[context] = stamp
        for item in items where item.id > 0 {
            let witness = witnessKey(item: item, deduplicate: policy.deduplicateMediaAssets)
            guard !witness.isEmpty else { continue }
            for tag in item.tags ?? [] {
                guard let tagID = tag.id, tagID > 0 else { continue }
                let key = Key(context: context, tagID: tagID)
                var record = records[key] ?? TagRecord(witnesses: [], emptyUntil: nil, touchedAt: stamp)
                record.witnesses.removeAll { $0.key == witness }
                record.witnesses.append(Witness(key: witness, seenAt: stamp))
                record.witnesses.sort { $0.seenAt > $1.seenAt }
                record.witnesses = Array(record.witnesses.prefix(maxWitnesses))
                record.emptyUntil = nil
                record.touchedAt = stamp
                records[key] = record
            }
        }
        trim()
        revision &+= 1
        scheduleWriteIfNeeded()
    }

    func recordEmpty(tagID: Int, scope: String, policy: TagAvailabilityPolicy) {
        guard tagID > 0 else { return }
        let context = contextHash(scope: scope, policy: policy)
        let stamp = now()
        contextTouches[context] = stamp
        let key = Key(context: context, tagID: tagID)
        var record = records[key] ?? TagRecord(witnesses: [], emptyUntil: nil, touchedAt: stamp)
        record.emptyUntil = stamp.addingTimeInterval(24 * 60 * 60)
        record.touchedAt = stamp
        records[key] = record
        trim()
        revision &+= 1
        scheduleWriteIfNeeded()
    }

    func estimate(tagID: Int, scope: String, policy: TagAvailabilityPolicy) -> TagObservationEstimate? {
        guard tagID > 0 else { return nil }
        let context = contextHash(scope: scope, policy: policy)
        guard let record = records[Key(context: context, tagID: tagID)] else { return nil }
        let instant = now()
        let cutoff = instant.addingTimeInterval(-30 * 24 * 60 * 60)
        let recent = record.witnesses.filter { $0.seenAt >= cutoff && $0.seenAt <= instant }
        let last = record.witnesses.map(\.seenAt).max()
        let activeEmpty = record.emptyUntil.flatMap { $0 > instant ? $0 : nil }
        return .init(countLowerBound: recent.count, lastSeen: last, emptyUntil: activeEmpty)
    }

    func flush() async {
        guard rootURL != nil else { return }
        if !loaded {
            await activate(scope: "")
            guard loaded else { return }
        }
        debounceTask?.cancel()
        debounceTask = nil
        let targetRevision = revision
        while persistenceWritable && persistedRevision < targetRevision {
            if let writer = pendingWrite {
                let (writtenRevision, success) = await writer.task.value
                if pendingWrite?.id == writer.id { pendingWrite = nil }
                if success { persistedRevision = max(persistedRevision, writtenRevision) }
                else { persistenceWritable = false; return }
            } else {
                startWriter()
            }
        }
    }

    private func scheduleWriteIfNeeded() {
        guard rootURL != nil, persistenceWritable else { return }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            await self.debounceElapsed()
        }
    }

    private func debounceElapsed() async {
        debounceTask = nil
        guard persistenceWritable else { return }
        if !loaded { await activate(scope: "") }
        guard loaded, persistenceWritable else { return }
        while let writer = pendingWrite {
            let (writtenRevision, success) = await writer.task.value
            if pendingWrite?.id == writer.id { pendingWrite = nil }
            if success { persistedRevision = max(persistedRevision, writtenRevision) }
            else { persistenceWritable = false; return }
        }
        if persistedRevision < revision { startWriter() }
    }

    private func startWriter() {
        guard let rootURL, persistenceWritable, loaded, pendingWrite == nil else { return }
        let snapshot = makeDiskFile()
        let snapshotRevision = revision
        let fileURL = rootURL.appendingPathComponent(fileName)
        let writerID = UUID()
        let writer = Task.detached(priority: .utility) {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                var diskSnapshot = snapshot
                var data = try encoder.encode(diskSnapshot)
                // Keep the full in-memory LRU state; only the persisted snapshot sheds
                // oldest whole contexts until it fits the bounded file budget.
                while data.count > 8 * 1024 * 1024, !diskSnapshot.contexts.isEmpty {
                    diskSnapshot.contexts.removeLast()
                    data = try encoder.encode(diskSnapshot)
                }
                guard data.count <= 8 * 1024 * 1024 else { return (snapshotRevision, false) }
                try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
                try Self.applyProtection(to: rootURL)
                try data.write(to: fileURL, options: .atomic)
                try Self.applyProtection(to: fileURL)
                return (snapshotRevision, true)
            } catch { return (snapshotRevision, false) }
        }
        pendingWrite = (writerID, writer)
    }

    nonisolated private static func applyProtection(to url: URL) throws {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    private func isValid(_ file: DiskFile) -> Bool {
        guard file.contexts.count <= maxContexts else { return false }
        var contextHashes = Set<String>()
        for context in file.contexts {
            guard context.hash.count == 64,
                  context.hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  contextHashes.insert(context.hash).inserted,
                  context.tags.count <= maxTagsPerContext,
                  context.touchedAt.timeIntervalSince1970.isFinite else { return false }
            var tagIDs = Set<Int>()
            for tag in context.tags {
                guard tag.tagID > 0, tagIDs.insert(tag.tagID).inserted,
                      tag.record.witnesses.count <= maxWitnesses,
                      tag.record.touchedAt.timeIntervalSince1970.isFinite,
                      tag.record.emptyUntil.map({ $0.timeIntervalSince1970.isFinite }) ?? true else { return false }
                var witnessKeys = Set<String>()
                for witness in tag.record.witnesses {
                    guard witness.seenAt.timeIntervalSince1970.isFinite, isValidWitnessKey(witness.key),
                          witnessKeys.insert(witness.key).inserted else { return false }
                }
            }
        }
        return true
    }

    private func isValidWitnessKey(_ key: String) -> Bool {
        if key.hasPrefix("id:") {
            let digits = key.dropFirst(3)
            return !digits.isEmpty && digits.utf8.allSatisfy { (48...57).contains($0) } && (Int(digits) ?? 0) > 0
        }
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "civitai" && ["image", "video"].contains(String(parts[1])) &&
            UUID(uuidString: String(parts[2])) != nil
    }

    private func witnessKey(item: MediaItem, deduplicate: Bool) -> String {
        guard deduplicate, let asset = item.mediaAssetKey else { return "id:\(item.id)" }
        let parts = asset.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "civitai", ["image", "video"].contains(String(parts[1])),
              UUID(uuidString: String(parts[2])) != nil else { return "id:\(item.id)" }
        return asset
    }

    private func contextHash(scope: String, policy: TagAvailabilityPolicy) -> String {
        let tags = policy.blockedTags.map(TagPolicy.normalize).sorted().joined(separator: "\u{1f}")
        let authorIDs = policy.blockedAuthorIDs.sorted().map(String.init).joined(separator: ",")
        let handles = policy.blockedAuthorHandles.map(AuthorHandlePolicy.normalize).sorted().joined(separator: "\u{1f}")
        let canonical = [scope, tags, authorIDs, handles, policy.deduplicateMediaAssets ? "1" : "0"].joined(separator: "\u{1e}")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func trim() {
        var contexts = Set(records.keys.map(\.context))
        while contexts.count > maxContexts {
            guard let oldest = contexts.min(by: { (contextTouches[$0] ?? .distantPast) < (contextTouches[$1] ?? .distantPast) }) else { break }
            records = records.filter { $0.key.context != oldest }
            contextTouches.removeValue(forKey: oldest)
            contexts.remove(oldest)
        }
        for context in contexts {
            let keys = records.keys.filter { $0.context == context }
            if keys.count > maxTagsPerContext {
                let remove = keys.sorted { (records[$0]?.touchedAt ?? .distantPast) < (records[$1]?.touchedAt ?? .distantPast) }
                    .prefix(keys.count - maxTagsPerContext)
                for key in remove { records.removeValue(forKey: key) }
            }
        }
    }

    private func makeDiskFile() -> DiskFile {
        let contexts = Dictionary(grouping: records, by: { $0.key.context }).map { hash, values in
            DiskContext(hash: hash, touchedAt: contextTouches[hash] ?? .distantPast,
                        tags: values.map { DiskTag(tagID: $0.key.tagID, record: $0.value) }.sorted { $0.tagID < $1.tagID })
        }.sorted { $0.touchedAt > $1.touchedAt }
        return DiskFile(version: 1, contexts: contexts)
    }

    private func merge(_ file: DiskFile) {
        for context in file.contexts {
            contextTouches[context.hash] = max(contextTouches[context.hash] ?? .distantPast, context.touchedAt)
            for diskTag in context.tags where diskTag.tagID > 0 {
                let key = Key(context: context.hash, tagID: diskTag.tagID)
                guard let current = records[key] else { records[key] = diskTag.record; continue }
                let merged = Dictionary((current.witnesses + diskTag.record.witnesses).map { ($0.key, $0) }, uniquingKeysWith: { a, b in a.seenAt >= b.seenAt ? a : b })
                var record = current
                record.witnesses = merged.values.sorted { $0.seenAt > $1.seenAt }.prefix(maxWitnesses).map { $0 }
                if diskTag.record.touchedAt > current.touchedAt {
                    record.emptyUntil = diskTag.record.emptyUntil
                } else {
                    record.emptyUntil = current.emptyUntil
                }
                record.touchedAt = max(current.touchedAt, diskTag.record.touchedAt)
                records[key] = record
            }
        }
    }

}
