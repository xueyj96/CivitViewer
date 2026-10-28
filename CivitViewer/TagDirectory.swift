import Foundation
import Combine

enum TagCatalogQuery {
    // Tag discovery uses the public vocabulary, independently of media filters.
    // The server owns visibility, including its default scope for an empty query.
    static func input(keyword: String, page: Int) -> [String: Any] {
        var input: [String: Any] = ["limit": 20, "page": page, "include": ["nsfwLevel"]]
        let normalized = TagPolicy.normalize(keyword)
        if !normalized.isEmpty { input["query"] = normalized }
        return input
    }
}
enum TagDirectoryQuality {
    static func includes(_ name: String) -> Bool {
        let value = TagPolicy.normalize(name)
        guard value.unicodeScalars.contains(where: CharacterSet.letters.contains) else { return false }
        let suffix = #"(?:\s*(?:\((?:style|aesthetic)\)|style|aesthetic))?$"#
        let decade = #"^(?:\d{2}|\d{4})['’]?s"# + suffix
        let century = #"^\d{1,2}(?:st|nd|rd|th)?[\s-]*century"# + suffix
        let chineseDate = #"^\d{1,4}(?:年(?:代)?|年代|世纪)(?:风格)?$"#
        return ![decade, century, chineseDate].contains { value.range(of: $0, options: .regularExpression) != nil }
    }
}

enum TagDirectoryMode: String, CaseIterable, Identifiable {
    case common, catalog
    var id: Self { self }
    var title: String { self == .common ? "站内常用" : "标签目录" }
}
struct TagDirectoryCursor {
    let page: Int
    var local: LocalTagCursor? = nil
}
struct TagDirectoryPage {
    let items: [SearchTag]
    let next: TagDirectoryCursor?
}
@MainActor protocol TagDirectorySource: AnyObject {
    var feedIdentity: String { get }
    var tagLookupIdentity: String { get }
    func commonTags() async throws -> [SearchTag]
    func catalogTags(keyword: String, page: Int) async throws -> [SearchTag]
    func exactTag(name: String) async throws -> SearchTag?
    func directoryPage(mode: TagDirectoryMode, keyword: String, cursor: TagDirectoryCursor?) async throws -> TagDirectoryPage
    func onlineTagPage(mode: TagDirectoryMode, keyword: String, page: Int) async throws -> [SearchTag]?
    func rememberTags(_ tags: [SearchTag], common: Bool, identity: String) async throws
}
extension TagDirectorySource {
    var tagLookupIdentity: String { feedIdentity }
    func onlineTagPage(mode: TagDirectoryMode, keyword: String, page: Int) async throws -> [SearchTag]? { nil }
    func rememberTags(_ tags: [SearchTag], common: Bool, identity: String) async throws {}
    func directoryPage(mode: TagDirectoryMode, keyword: String, cursor: TagDirectoryCursor?) async throws -> TagDirectoryPage {
        let number = cursor?.page ?? 1
        let tags = try await (mode == .common ? commonTags() : catalogTags(keyword: keyword, page: number))
        return .init(items: tags, next: mode == .common || tags.count < 20 ? nil : .init(page: number + 1))
    }
}
@MainActor final class TagDirectoryStore: ObservableObject {
    struct Key: Equatable { let mode: TagDirectoryMode; let keyword: String; let identity: String }
    @Published private(set) var tags: [SearchTag] = []
    @Published private(set) var key: Key?
    @Published private(set) var loading = false
    @Published private(set) var reachedEnd = false
    @Published private(set) var error: String?
    @Published private(set) var hiddenNoiseCount = 0
    @Published private(set) var localLoading = false
    @Published private(set) var onlineLoading = false
    @Published private(set) var pendingDebounce = false
    @Published private(set) var onlineError: String?
    @Published private(set) var cacheError: String?

    private struct CacheKey: Hashable {
        let identity: String
        let mode: TagDirectoryMode
        let keyword: String
        let page: Int
    }
    private struct CacheEntry {
        let tags: [SearchTag]
        let savedAt: Date
        var lastAccess: UInt64
    }
    private struct SnapshotKey: Hashable {
        let identity: String
        let mode: TagDirectoryMode
        let keyword: String
    }
    private struct QuerySnapshot {
        let localItems: [SearchTag]
        let onlineItems: [SearchTag]
        let localCursor: TagDirectoryCursor?
        let localEnded: Bool
        let localPageIDs: Set<Int>
        let onlinePage: Int
        let onlineEnded: Bool
        let onlinePageIDs: Set<Int>
        let onlineCommonReceived: Bool
        let savedAt: Date
        var lastAccess: UInt64
        var rowCount: Int { localItems.count + onlineItems.count }
    }
    private var cache: [CacheKey: CacheEntry] = [:]
    private var snapshots: [SnapshotKey: QuerySnapshot] = [:]
    private var cacheIdentity: String?
    private var cacheClock: UInt64 = 0
    private let cachePageLimit: Int
    private let cacheTTL: TimeInterval
    private let emptyCacheTTL: TimeInterval
    private let debounceNanoseconds: UInt64
    private let now: () -> Date
    private let diagnostics: LocalDiagnosticsStore?

    private var generation = 0
    private var acceptsRequests = false
    private var localCursor: TagDirectoryCursor?
    private var localEnded = false
    private var localPageIDs = Set<Int>()
    private var localItems: [SearchTag] = []
    private var onlinePage = 1
    private var onlineEnded = false
    private var onlinePageIDs = Set<Int>()
    private var onlineItems: [SearchTag] = []
    private var onlineCommonReceived = false
    private var onlineUnsupported = false

    init(debounceNanoseconds: UInt64 = 300_000_000, cachePageLimit: Int = 64,
         cacheTTL: TimeInterval = 300, emptyCacheTTL: TimeInterval = 30,
         now: @escaping () -> Date = Date.init, diagnostics: LocalDiagnosticsStore? = nil) {
        self.debounceNanoseconds = debounceNanoseconds
        self.cachePageLimit = min(max(1, cachePageLimit), 64)
        self.cacheTTL = max(0, cacheTTL)
        self.emptyCacheTTL = max(0, emptyCacheTTL)
        self.now = now
        self.diagnostics = diagnostics
    }

    func reload(key requestedKey: Key, source: any TagDirectorySource, forceRemote: Bool = false) async {
        guard !Task.isCancelled, requestedKey.identity == source.tagLookupIdentity else { return }
        generation += 1
        acceptsRequests = true
        let revision = generation
        let requestKey = requestedKey
        if cacheIdentity != requestKey.identity {
            cache.removeAll(); snapshots.removeAll(); cacheClock = 0; cacheIdentity = requestKey.identity
        }
        localLoading = false; onlineLoading = false; pendingDebounce = false; loading = false
        key = requestKey; tags = []; localCursor = nil; localEnded = false; localPageIDs = []; localItems = []
        onlinePage = 1; onlineEnded = false; onlinePageIDs = []; onlineItems = []; onlineCommonReceived = false; onlineUnsupported = false
        reachedEnd = false; error = nil; onlineError = nil; cacheError = nil; hiddenNoiseCount = 0
        if !forceRemote, restoreSnapshot(requestKey) { return }
        if forceRemote { snapshots.removeValue(forKey: snapshotKey(requestKey)) }
        await loadLocalBatch(source: source, requestKey: requestKey, revision: revision)
        guard isCurrent(requestKey, source: source, revision: revision) else { return }
        do {
            try Task.checkCancellation()
            if debounceNanoseconds > 0 {
                pendingDebounce = true; refreshLoading()
                try await Task.sleep(nanoseconds: debounceNanoseconds)
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            if isCurrent(requestKey, source: source, revision: revision) {
                generation += 1; pendingDebounce = false; error = "标签读取已中止，请重试。"; refreshLoading()
            }
            return
        } catch { return }
        guard isCurrent(requestKey, source: source, revision: revision) else { return }
        await loadOnlineBatch(source: source, requestKey: requestKey, revision: revision, forceRemote: forceRemote)
        saveSnapshotIfSuccessful(requestKey, source: source, revision: revision)
    }

    func next(source: any TagDirectorySource) async {
        guard !Task.isCancelled, let requestKey = key, isCurrent(requestKey, source: source, revision: generation), !loading, !reachedEnd else { return }
        let revision = generation
        error = nil
        if !localEnded { await loadLocalBatch(source: source, requestKey: requestKey, revision: revision) }
        guard isCurrent(requestKey, source: source, revision: revision), !Task.isCancelled else { return }
        await loadOnlineBatch(source: source, requestKey: requestKey, revision: revision, forceRemote: false)
        saveSnapshotIfSuccessful(requestKey, source: source, revision: revision)
    }

    func retryOnline(source: any TagDirectorySource) async {
        guard !Task.isCancelled, let requestKey = key, isCurrent(requestKey, source: source, revision: generation), !onlineLoading else { return }
        let revision = generation
        await loadOnlineBatch(source: source, requestKey: requestKey, revision: revision, forceRemote: false)
        saveSnapshotIfSuccessful(requestKey, source: source, revision: revision)
    }

    func cancel() {
        generation += 1
        acceptsRequests = false
        localLoading = false; onlineLoading = false; pendingDebounce = false; loading = false
    }

    private func loadLocalBatch(source: any TagDirectorySource, requestKey: Key, revision: Int) async {
        guard !localLoading, !localEnded, isCurrent(requestKey, source: source, revision: revision) else { return }
        localLoading = true; refreshLoading()
        var added = 0
        do {
            for _ in 0..<3 {
                try Task.checkCancellation()
                guard isCurrent(requestKey, source: source, revision: revision) else { break }
                let page = try await source.directoryPage(mode: requestKey.mode, keyword: requestKey.keyword, cursor: localCursor)
                try Task.checkCancellation()
                guard isCurrent(requestKey, source: source, revision: revision) else { break }
                try validate(page.items, keyword: requestKey.keyword, limit: nil)
                let ids = page.items.map(\.id)
                if page.items.count >= 20 && !page.items.isEmpty && ids.allSatisfy({ localPageIDs.contains($0) }) {
                    throw ClientError.format("标签目录重复分页，请重试当前页。")
                }
                let beforeIDs = Set(tags.map(\.id))
                for tag in page.items {
                    localPageIDs.insert(tag.id)
                    upsert(tag, into: &localItems)
                }
                localCursor = page.next
                localEnded = page.next == nil
                rebuild()
                added += Set(tags.map(\.id)).subtracting(beforeIDs).count
                if localEnded || added >= 20 { break }
            }
            if isCurrent(requestKey, source: source, revision: revision) { error = nil }
        } catch is CancellationError {
            if isCurrent(requestKey, source: source, revision: revision) { error = "标签读取已中止，请重试。" }
        } catch {
            if isCurrent(requestKey, source: source, revision: revision) {
                self.error = error.localizedDescription; diagnostics?.note(area: .search, code: .storage)
            }
        }
        if revision == generation { localLoading = false; updateReachedEnd(); refreshLoading() }
    }

    private func loadOnlineBatch(source: any TagDirectorySource, requestKey: Key, revision: Int, forceRemote: Bool) async {
        guard !onlineLoading, !onlineEnded, isCurrent(requestKey, source: source, revision: revision) else { updateReachedEnd(); return }
        onlineLoading = true; pendingDebounce = false; refreshLoading()
        var added = 0
        do {
            for _ in 0..<3 {
                try Task.checkCancellation()
                guard isCurrent(requestKey, source: source, revision: revision) else { break }
                let pageNumber = onlinePage
                let remote = try await onlineTags(source: source, requestKey: requestKey, page: pageNumber, forceRemote: forceRemote, revision: revision)
                try Task.checkCancellation()
                guard isCurrent(requestKey, source: source, revision: revision) else { break }
                guard let result = remote.tags else { onlineUnsupported = true; onlineEnded = true; break }
                let commonSnapshot = requestKey.mode == .common && TagPolicy.normalize(requestKey.keyword).isEmpty
                let pageLimit = commonSnapshot ? 200 : 20
                try validate(result, keyword: requestKey.keyword, limit: pageLimit)
                if result.count >= 20 && !result.isEmpty && result.map(\.id).allSatisfy({ onlinePageIDs.contains($0) }) {
                    throw ClientError.format("线上标签重复分页，请重试当前页。")
                }
                // The unfiltered common endpoint is one authoritative ranked snapshot.
                if commonSnapshot { onlineCommonReceived = true }
                let commonEndsAfterThisResponse = commonSnapshot
                let beforeOnlineIDs = Set(onlineItems.map(\.id))
                for tag in result {
                    onlinePageIDs.insert(tag.id)
                    upsert(tag, into: &onlineItems)
                }
                onlinePage += 1
                onlineEnded = commonEndsAfterThisResponse || result.count < 20
                rebuild()
                added += onlineItems.filter { !beforeOnlineIDs.contains($0.id) && TagDirectoryQuality.includes($0.name) }.count
                onlineError = nil
                if !remote.fromCache {
                    saveCache(result, key: cacheKey(requestKey, page: pageNumber))
                }
                if !remote.fromCache, isCurrent(requestKey, source: source, revision: revision) {
                    do {
                        try await source.rememberTags(result, common: requestKey.mode == .common && TagPolicy.normalize(requestKey.keyword).isEmpty && pageNumber == 1, identity: requestKey.identity)
                        cacheError = nil
                    }
                    catch { if isCurrent(requestKey, source: source, revision: revision) { cacheError = error.localizedDescription; diagnostics?.note(area: .search, code: .storage) } }
                }
                if onlineEnded || added >= 20 { break }
            }
        } catch is CancellationError {
            if isCurrent(requestKey, source: source, revision: revision) { onlineError = "线上标签读取已中止，可重试。" }
        } catch {
            if isCurrent(requestKey, source: source, revision: revision) {
                onlineError = error.localizedDescription
                if case ClientError.http(let status) = error { diagnostics?.note(area: .search, code: .http, httpStatus: status) }
                else { diagnostics?.note(area: .search, code: .loadFailed) }
            }
        }
        if revision == generation { onlineLoading = false; updateReachedEnd(); refreshLoading() }
    }

    private func onlineTags(source: any TagDirectorySource, requestKey: Key, page: Int, forceRemote: Bool, revision: Int) async throws -> (tags: [SearchTag]?, fromCache: Bool) {
        let key = cacheKey(requestKey, page: page)
        if !forceRemote, let entry = cached(key) { return (entry, true) }
        let result = try await source.onlineTagPage(mode: requestKey.mode, keyword: TagPolicy.normalize(requestKey.keyword), page: page)
        guard isCurrent(requestKey, source: source, revision: revision) else { throw CancellationError() }
        guard let result else { return (nil, false) }
        let commonSnapshot = requestKey.mode == .common && TagPolicy.normalize(requestKey.keyword).isEmpty
        try validate(result, keyword: requestKey.keyword, limit: commonSnapshot ? 200 : 20)
        return (result, false)
    }

    private func cached(_ key: CacheKey) -> [SearchTag]? {
        guard var entry = cache[key] else { return nil }
        let ttl = entry.tags.isEmpty ? emptyCacheTTL : cacheTTL
        guard now().timeIntervalSince(entry.savedAt) <= ttl else { cache.removeValue(forKey: key); return nil }
        cacheClock &+= 1; entry.lastAccess = cacheClock; cache[key] = entry
        return entry.tags
    }

    private func saveCache(_ tags: [SearchTag], key: CacheKey) {
        cacheClock &+= 1
        cache[key] = CacheEntry(tags: tags, savedAt: now(), lastAccess: cacheClock)
        while cache.count > cachePageLimit, let oldest = cache.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key { cache.removeValue(forKey: oldest) }
    }

    private func cacheKey(_ key: Key, page: Int) -> CacheKey {
        CacheKey(identity: key.identity, mode: key.mode, keyword: TagPolicy.normalize(key.keyword), page: page)
    }

    private func snapshotKey(_ key: Key) -> SnapshotKey {
        SnapshotKey(identity: key.identity, mode: key.mode, keyword: TagPolicy.normalize(key.keyword))
    }

    private func restoreSnapshot(_ requestKey: Key) -> Bool {
        let key = snapshotKey(requestKey)
        guard var snapshot = snapshots[key] else { return false }
        let ttl = snapshot.rowCount == 0 ? emptyCacheTTL : cacheTTL
        guard now().timeIntervalSince(snapshot.savedAt) <= ttl else {
            snapshots.removeValue(forKey: key)
            return false
        }
        cacheClock &+= 1
        snapshot.lastAccess = cacheClock
        snapshots[key] = snapshot
        localItems = snapshot.localItems; onlineItems = snapshot.onlineItems
        localCursor = snapshot.localCursor; localEnded = snapshot.localEnded; localPageIDs = snapshot.localPageIDs
        onlinePage = snapshot.onlinePage; onlineEnded = snapshot.onlineEnded; onlinePageIDs = snapshot.onlinePageIDs
        onlineCommonReceived = snapshot.onlineCommonReceived
        error = nil; onlineError = nil; cacheError = nil
        rebuild()
        updateReachedEnd(); refreshLoading()
        return true
    }

    private func saveSnapshotIfSuccessful(_ requestKey: Key, source: any TagDirectorySource, revision: Int) {
        guard !Task.isCancelled, isCurrent(requestKey, source: source, revision: revision),
              !loading, error == nil, onlineError == nil, !onlineUnsupported,
              localItems.count + onlineItems.count <= 400 else { return }
        let key = snapshotKey(requestKey)
        cacheClock &+= 1
        snapshots[key] = QuerySnapshot(
            localItems: localItems, onlineItems: onlineItems,
            localCursor: localCursor, localEnded: localEnded, localPageIDs: localPageIDs,
            onlinePage: onlinePage, onlineEnded: onlineEnded, onlinePageIDs: onlinePageIDs,
            onlineCommonReceived: onlineCommonReceived, savedAt: now(), lastAccess: cacheClock
        )
        while snapshots.count > 16 || snapshots.values.reduce(0, { $0 + $1.rowCount }) > 2_000 {
            guard let oldest = snapshots.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key else { break }
            snapshots.removeValue(forKey: oldest)
        }
    }

    private func validate(_ items: [SearchTag], keyword: String, limit: Int?) throws {
        let normalized = TagPolicy.normalize(keyword)
        guard limit.map({ items.count <= $0 }) ?? true,
              items.allSatisfy({ $0.id > 0 && !TagPolicy.normalize($0.name).isEmpty && (normalized.isEmpty || TagPolicy.normalize($0.name).hasPrefix(normalized)) }) else {
            throw ClientError.invalidResponse
        }
    }

    private func upsert(_ tag: SearchTag, into items: inout [SearchTag]) {
        if let index = items.firstIndex(where: { $0.id == tag.id }) { items[index] = tag }
        else { items.append(tag) }
    }

    private func rebuild() {
        var byID: [Int: SearchTag] = [:]
        for tag in localItems { byID[tag.id] = tag }
        for tag in onlineItems { byID[tag.id] = tag }
        let normalizedKeyword = TagPolicy.normalize(key?.keyword ?? "")
        var ordered: [SearchTag]
        if key?.mode == .common && normalizedKeyword.isEmpty {
            var orderedIDs = onlineCommonReceived ? onlineItems.map(\.id) : onlineItems.map(\.id) + localItems.map(\.id)
            var used = Set<Int>()
            orderedIDs = orderedIDs.filter { used.insert($0).inserted }
            ordered = orderedIDs.compactMap { byID[$0] }
        } else {
            ordered = Array(byID.values)
            ordered.sort {
                let lhs = TagPolicy.normalize($0.name), rhs = TagPolicy.normalize($1.name)
                if !normalizedKeyword.isEmpty {
                    let leftExact = lhs == normalizedKeyword, rightExact = rhs == normalizedKeyword
                    if leftExact != rightExact { return leftExact }
                }
                if lhs != rhs { return lhs < rhs }
                return $0.id < $1.id
            }
        }
        hiddenNoiseCount = ordered.filter { !TagDirectoryQuality.includes($0.name) }.count
        tags = ordered.filter { TagDirectoryQuality.includes($0.name) }
        updateReachedEnd()
    }

    private func isCurrent(_ requestKey: Key, source: any TagDirectorySource, revision: Int) -> Bool {
        acceptsRequests && revision == generation && key == requestKey && requestKey.identity == source.tagLookupIdentity
    }
    private func updateReachedEnd() { reachedEnd = localEnded && onlineEnded }
    private func refreshLoading() { loading = localLoading || onlineLoading || pendingDebounce }
}
