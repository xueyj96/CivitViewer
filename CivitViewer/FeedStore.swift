import Foundation
import Combine

@MainActor
final class FeedStore: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var loading = false
    @Published private(set) var reachedEnd = false
    @Published var error: String?
    @Published private(set) var hiddenByTags = 0
    @Published private(set) var hiddenByAuthors = 0
    @Published private(set) var unverifiedTags = 0
    @Published private(set) var duplicatesDiscarded = 0
    @Published private(set) var hiddenByDuration = 0
    @Published private(set) var unverifiedDuration = 0
    @Published private(set) var durationMetadataFailedPages = 0
    @Published private(set) var searchProgress: SearchScanProgress?
    @Published private(set) var continuationState: FeedContinuationState = .ready
    @Published private(set) var restartRetryAvailableAt: Date?
    private var accumulator = FeedAccumulator()
    private var generation = 0
    private var filter = FeedFilter()
    private var source: FeedSource = .discovery
    private(set) var requestKey: FeedStoreRequestKey?
    private var loadState: FeedLoadState = .incomplete
    private var activationPendingRevision: Int?
    private var activePageLease: FeedCancellationLease?
    private var activePageTask: Task<MediaPage, Error>?
    private var activeSliceTask: Task<Void, Error>?
    private var restartRevision: Int?
    private var restartKey: FeedStoreRequestKey?
    private var restartLease: FeedCancellationLease?
    private var restartTask: Task<FeedRestartResult, Never>?
    private var restartBlockedTags: Set<String>?
    private var restartPreviousContinuationState: FeedContinuationState?
    private var blockedTags = Set<String>()
    private var deduplicateMediaAssets = false
    private var seenCursors = Set<String>()
    private var configured = false
    private var tagPolicyDeferred = false
    private let preferences: UserDefaults
    private var preferenceObserver: AnyCancellable?
    private let authorBlocks: AuthorBlocklist?
    private var authorBlockObserver: AnyCancellable?
    private var assetPolicyOverride: Bool?
    private let diagnostics: LocalDiagnosticsStore?
    private let now: @MainActor () -> Date
    private let slicePause: @MainActor (Int) async throws -> Void
    private var consecutiveRequestFailures = 0
    private var restartRetryKey: FeedStoreRequestKey?
    private var restartRetryError: String?
    private var consecutiveRestartFailures = 0

    private func resetRestartRetry() {
        restartRetryAvailableAt = nil; restartRetryKey = nil; restartRetryError = nil
        consecutiveRestartFailures = 0
    }

    var canAutomaticallyContinue: Bool {
        let cancelledOwner = loading && activePageLease?.isCancelled == true
        return configured && restartRevision == nil && activationPendingRevision != generation &&
            (!loading || cancelledOwner) && !reachedEnd && continuationState.failure == nil &&
            (!continuationState.isLoading || cancelledOwner)
    }
    var retryAvailableAt: Date? { continuationState.retryAvailableAt }
    var canRetryContinuation: Bool {
        guard let failure = continuationState.failure, !failure.requiresRestart else { return false }
        return failure.retryAvailableAt.map { now() >= $0 } ?? true
    }

    private var currentAssetDeduplicationPolicy: Bool {
        assetPolicyOverride ?? (preferences.object(forKey: "deduplicateMedia") as? Bool ?? true)
    }

    init(preferences: UserDefaults = .standard, diagnostics: LocalDiagnosticsStore? = nil,
         authorBlocks: AuthorBlocklist? = nil,
         now: @escaping @MainActor () -> Date = { Date() },
         slicePause: @escaping @MainActor (Int) async throws -> Void = { slice in
             try await Task.sleep(nanoseconds: UInt64(min(1_000, 250 * min(slice, 4))) * 1_000_000)
         }) {
        self.preferences = preferences
        self.diagnostics = diagnostics
        self.authorBlocks = authorBlocks
        self.now = now
        self.slicePause = slicePause
        preferenceObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.refreshAssetPolicy() } }
        authorBlockObserver = authorBlocks?.$entries.sink { [weak self] _ in
            Task { @MainActor in self?.applyCurrentAuthorBlocks() }
        }
    }

    private func refreshAssetPolicy() {
        let desired = currentAssetDeduplicationPolicy
        guard configured, desired != deduplicateMediaAssets else { return }
        deduplicateMediaAssets = desired; accumulator.setDeduplicateMediaAssets(desired)
        items = accumulator.items; duplicatesDiscarded = accumulator.duplicateCount
    }

    func clear() {
        resetRestartRetry()
        generation += 1; cancelRestart(); cancelPageScan(); accumulator = FeedAccumulator(); items = []; configured = false; requestKey = nil; loadState = .incomplete; activationPendingRevision = nil; tagPolicyDeferred = false
        loading = false; reachedEnd = false; error = nil
        continuationState = .ready; consecutiveRequestFailures = 0
        hiddenByTags = 0; unverifiedTags = 0; duplicatesDiscarded = 0; seenCursors = []; searchProgress = nil
        hiddenByAuthors = 0; hiddenByDuration = 0; unverifiedDuration = 0; durationMetadataFailedPages = 0
    }

    private func currentAuthorBlocks() -> (ids: Set<Int>, handles: Set<String>) {
        guard let authorBlocks else { return ([], []) }
        return (authorBlocks.blockedIDs, authorBlocks.blockedHandles)
    }
    private func applyCurrentAuthorBlocks() {
        guard configured else { return }
        let snapshot = currentAuthorBlocks()
        accumulator.applyBlockedAuthors(ids: snapshot.ids, handles: snapshot.handles)
        items = accumulator.items; hiddenByAuthors = accumulator.blockedAuthorCount
        hiddenByDuration = accumulator.hiddenByDuration; unverifiedDuration = accumulator.unverifiedDuration
        hiddenByTags = accumulator.blockedCount; unverifiedTags = accumulator.unverifiedCount
        duplicatesDiscarded = accumulator.duplicateCount
    }
    func applyBlockedAuthors(ids: Set<Int>, handles: Set<String>) {
        guard authorBlocks != nil else { return }
        accumulator.applyBlockedAuthors(ids: ids, handles: handles)
        items = accumulator.items; hiddenByAuthors = accumulator.blockedAuthorCount
        hiddenByDuration = accumulator.hiddenByDuration; unverifiedDuration = accumulator.unverifiedDuration
        hiddenByTags = accumulator.blockedCount; unverifiedTags = accumulator.unverifiedCount
        duplicatesDiscarded = accumulator.duplicateCount
    }

    func applyBlockedTags(_ names: Set<String>) {
        blockedTags = names
        if restartRevision != nil { restartBlockedTags = names }
        guard !tagPolicyDeferred else { return }
        accumulator.applyBlockedTags(names)
        items = accumulator.items; hiddenByTags = accumulator.blockedCount
        unverifiedTags = accumulator.unverifiedCount; duplicatesDiscarded = accumulator.duplicateCount
    }
    func setTagPolicyDeferred(_ value: Bool) { tagPolicyDeferred = value; if !value { applyBlockedTags(blockedTags) } }

    /// Configures one source/filter/account tuple. Switching configurations is
    /// debounced so transient view state does not issue a request for every step.
    func activate(session: any FeedPageReading, filter: FeedFilter, source: FeedSource,
                  blockedTags: Set<String> = [], deduplicateMediaAssets: Bool? = nil,
                  force: Bool = false) async -> FeedCommit {
        if Task.isCancelled {
            return FeedCommit(status: .cancelled, key: requestKey, revision: generation, state: loadState)
        }
        let targetKey = FeedStoreRequestKey(identity: session.feedIdentity, filter: filter, source: source)
        if restartRetryKey != targetKey { resetRestartRetry() }
        if let restartRevision {
            if self.restartKey == targetKey {
                return FeedCommit(status: .unchanged, key: targetKey, revision: restartRevision, state: .incomplete)
            }
            generation += 1; cancelRestart(); cancelPageScan(); loading = false
        }
        if !force, requestKey == targetKey {
            if activationPendingRevision != generation {
                if loadState == .incomplete { return await next(session: session) }
                applyPolicies(blockedTags: blockedTags, deduplicateMediaAssets: deduplicateMediaAssets)
                return FeedCommit(status: .unchanged, key: targetKey, revision: generation, state: loadState)
            }
            // The previous caller owns only the pending debounce. Taking a new
            // generation here lets this caller replace a cancelled owner instead
            // of inheriting a pending state that may never issue a request.
        }
        generation += 1
        let requestGeneration = generation
        requestKey = targetKey
        activationPendingRevision = requestGeneration
        self.filter = filter; self.source = source
        configured = true
        let assetPolicy = deduplicateMediaAssets ?? currentAssetDeduplicationPolicy
        assetPolicyOverride = deduplicateMediaAssets
        self.blockedTags = blockedTags; self.deduplicateMediaAssets = assetPolicy
        loadState = .incomplete
        cancelPageScan()
        accumulator = FeedAccumulator(blockedTags: blockedTags, deduplicateMediaAssets: assetPolicy, videoDurationRange: filter.videoDurationRange)
        let authorSnapshot = currentAuthorBlocks()
        accumulator.applyBlockedAuthors(ids: authorSnapshot.ids, handles: authorSnapshot.handles)
        items = []; error = nil; reachedEnd = false; loading = false; seenCursors = []; searchProgress = nil
        continuationState = .ready; consecutiveRequestFailures = 0
        hiddenByTags = 0; unverifiedTags = 0; duplicatesDiscarded = 0
        hiddenByAuthors = 0; hiddenByDuration = 0; unverifiedDuration = 0; durationMetadataFailedPages = 0
        do { try await Task.sleep(nanoseconds: 250_000_000) }
        catch {
            if activationPendingRevision == requestGeneration { activationPendingRevision = nil }
            return FeedCommit(status: .cancelled, key: targetKey, revision: requestGeneration, state: .incomplete)
        }
        guard requestGeneration == generation, targetKey == requestKey,
              targetKey.identity == session.feedIdentity, !Task.isCancelled else {
            if activationPendingRevision == requestGeneration { activationPendingRevision = nil }
            return FeedCommit(status: .superseded, key: targetKey, revision: requestGeneration, state: nil)
        }
        activationPendingRevision = nil
        return await next(session: session)
    }

    private func applyPolicies(blockedTags: Set<String>, deduplicateMediaAssets: Bool?) {
        if self.blockedTags != blockedTags { self.blockedTags = blockedTags; if !tagPolicyDeferred { accumulator.applyBlockedTags(blockedTags) } }
        if let deduplicateMediaAssets, self.deduplicateMediaAssets != deduplicateMediaAssets {
            assetPolicyOverride = deduplicateMediaAssets; self.deduplicateMediaAssets = deduplicateMediaAssets
            accumulator.setDeduplicateMediaAssets(deduplicateMediaAssets)
        }
        items = accumulator.items; hiddenByDuration = accumulator.hiddenByDuration; unverifiedDuration = accumulator.unverifiedDuration
        hiddenByTags = accumulator.blockedCount; unverifiedTags = accumulator.unverifiedCount
        duplicatesDiscarded = accumulator.duplicateCount; hiddenByAuthors = accumulator.blockedAuthorCount
    }

    /// Automatic owners must stop at an error. Only an explicit retry may
    /// resume a transport failure, and a cursor stall needs a from-start refresh.
    @discardableResult
    func nextAutomatically(session: any FeedPageReading) async -> FeedCommit {
        guard canAutomaticallyContinue else {
            return FeedCommit(status: .unchanged, key: requestKey, revision: generation, state: loadState)
        }
        return await next(session: session)
    }

    @discardableResult
    func next(session: any FeedPageReading) async -> FeedCommit {
        if Task.isCancelled {
            return FeedCommit(status: .cancelled, key: requestKey, revision: generation, state: loadState)
        }
        guard configured else { return FeedCommit(status: .unchanged, key: nil, revision: generation, state: nil) }
        let activeKey = requestKey ?? FeedStoreRequestKey(identity: session.feedIdentity, filter: filter, source: source)
        if let restartRevision {
            return FeedCommit(status: .unchanged, key: activeKey, revision: restartRevision, state: loadState)
        }
        requestKey = activeKey
        if activationPendingRevision == generation {
            return FeedCommit(status: .unchanged, key: activeKey, revision: generation, state: .incomplete)
        }
        if continuationState.failure != nil, !canRetryContinuation {
            return FeedCommit(status: .unchanged, key: activeKey, revision: generation, state: loadState)
        }
        if loading {
            guard activePageLease?.isCancelled == true else {
                return FeedCommit(status: .unchanged, key: activeKey, revision: generation, state: loadState)
            }
            // The caller that owned the in-flight page is cancelled. This caller
            // takes a new generation and retries at the still-uncommitted cursor.
            cancelPageScan()
            generation += 1; loading = false; loadState = .incomplete
        }
        guard !reachedEnd else { loadState = .ended; continuationState = .ended; return FeedCommit(status: .unchanged, key: activeKey, revision: generation, state: loadState) }
        guard activeKey.identity == session.feedIdentity else { loading = false; generation += 1; loadState = .incomplete; continuationState = .ready; return FeedCommit(status: .superseded, key: activeKey, revision: generation, state: nil) }
        loading = true; error = nil; continuationState = .loading
        let requestGeneration = generation
        let lease = FeedCancellationLease()
        activePageLease = lease
        defer { if requestGeneration == generation { loading = false; activePageLease = nil; activePageTask = nil; activeSliceTask = nil } }
        return await withTaskCancellationHandler {
            await performNext(session: session, key: activeKey, revision: requestGeneration, lease: lease)
        } onCancel: {
            lease.cancel()
        }
    }

    private func performNext(session: any FeedPageReading, key activeKey: FeedStoreRequestKey,
                             revision requestGeneration: Int, lease: FeedCancellationLease) async -> FeedCommit {
        func stopped() -> FeedCommit? {
            if Task.isCancelled {
                if requestGeneration == generation, activeKey == requestKey {
                    loadState = .incomplete; continuationState = reachedEnd ? .ended : .ready
                }
                return FeedCommit(status: .cancelled, key: activeKey, revision: requestGeneration, state: .incomplete)
            }
            guard requestGeneration == generation, activeKey == requestKey else {
                return FeedCommit(status: .superseded, key: activeKey, revision: requestGeneration, state: nil)
            }
            if lease.isCancelled {
                loadState = .incomplete; continuationState = reachedEnd ? .ended : .ready
                return FeedCommit(status: .cancelled, key: activeKey, revision: requestGeneration, state: .incomplete)
            }
            guard activeKey.identity == session.feedIdentity else {
                loading = false; generation += 1; loadState = .incomplete; continuationState = .ready
                cancelPageScan()
                return FeedCommit(status: .superseded, key: activeKey, revision: generation, state: nil)
            }
            return nil
        }
        var scannedPages = 0
        do {
            // Four pages are one scheduling slice, never an artificial user-facing
            // end. Keep one owner while skipping filtered/duplicate batches.
            while true {
                if let stopped = stopped() { return stopped }
                let pageTask = Task { @MainActor in try await fetchPage(session: session, key: activeKey, cursor: accumulator.cursor) }
                activePageTask = pageTask
                let page = try await withTaskCancellationHandler {
                    try await pageTask.value
                } onCancel: {
                    lease.cancel()
                    pageTask.cancel()
                }
                if let stopped = stopped() { return stopped }
                if page.durationEnrichmentFailed {
                    durationMetadataFailedPages += 1
                    if let status = page.durationEnrichmentHTTPStatus { throw ClientError.http(status) }
                    throw ClientError.format("无法取得视频时长，请稍后重试。")
                }
                let authorSnapshot = currentAuthorBlocks()
                accumulator.applyBlockedAuthors(ids: authorSnapshot.ids, handles: authorSnapshot.handles)
                searchProgress = page.searchProgress
                let count = accumulator.items.count
                accumulator.append(page, kind: filter.effectiveKind)
                items = accumulator.items; reachedEnd = accumulator.reachedEnd
                hiddenByDuration = accumulator.hiddenByDuration; unverifiedDuration = accumulator.unverifiedDuration
                hiddenByTags = accumulator.blockedCount; unverifiedTags = accumulator.unverifiedCount
                hiddenByAuthors = accumulator.blockedAuthorCount
                duplicatesDiscarded = accumulator.duplicateCount
                if let cursor = accumulator.cursor, !seenCursors.insert(cursor).inserted {
                    let message = "加载停滞：站点重复返回分页位置，请从头刷新。"
                    error = message; loadState = .failed; continuationState = .failed(.stalled(message: message))
                    return FeedCommit(status: .committed, key: activeKey, revision: requestGeneration, state: .failed)
                }
                if items.count > count || reachedEnd {
                    consecutiveRequestFailures = 0
                    loadState = reachedEnd ? .ended : .loaded
                    continuationState = reachedEnd ? .ended : .ready
                    return FeedCommit(status: .committed, key: activeKey, revision: requestGeneration, state: loadState)
                }
                scannedPages += 1
                continuationState = .scanning
                if scannedPages.isMultiple(of: 4) {
                    let slice = scannedPages / 4
                    let wait = Task { @MainActor in try await slicePause(slice) }
                    activeSliceTask = wait
                    try await withTaskCancellationHandler { try await wait.value } onCancel: {
                        lease.cancel(); wait.cancel()
                    }
                    activeSliceTask = nil
                } else {
                    await Task.yield()
                }
            }
        } catch is CancellationError {
            if let stopped = stopped() { return stopped }
            if requestGeneration == generation, activeKey == requestKey { loadState = .incomplete; continuationState = .ready }
            return FeedCommit(status: .cancelled, key: activeKey, revision: requestGeneration, state: .incomplete)
        } catch {
            if let stopped = stopped() { return stopped }
            if requestGeneration == generation {
                self.error = error.localizedDescription
                loadState = .failed
                consecutiveRequestFailures = min(6, consecutiveRequestFailures + 1)
                let rateLimited: Bool = if case ClientError.http(429) = error { true } else { false }
                let delay = min(rateLimited ? 30.0 : 8.0, (rateLimited ? 3.0 : 0.5) * pow(2, Double(consecutiveRequestFailures - 1)))
                continuationState = .failed(.request(message: error.localizedDescription, retryAfter: now().addingTimeInterval(delay)))
                let area: DiagnosticArea = if case .search = source { .search } else { .playback }
                if case ClientError.http(let status) = error { diagnostics?.note(area: area, code: .http, httpStatus: status) }
                else { diagnostics?.note(area: area, code: .loadFailed) }
                return FeedCommit(status: .committed, key: activeKey, revision: requestGeneration, state: .failed)
            }
            return FeedCommit(status: .superseded, key: activeKey, revision: requestGeneration, state: nil)
        }
    }

    private func cancelPageScan() {
        activePageLease?.cancel(); activePageTask?.cancel(); activeSliceTask?.cancel()
        activePageLease = nil; activePageTask = nil; activeSliceTask = nil
    }

    private func fetchPage(session: any FeedPageReading, key: FeedStoreRequestKey, cursor: String?) async throws -> MediaPage {
        let page: MediaPage
        switch key.source {
        case .search(let target):
            page = try await session.searchMediaPage(target: target, filter: key.filter, cursor: cursor, includeTags: true)
        case .collection(let id):
            page = try await session.collectionPage(id: id, filter: key.filter, cursor: cursor, allAccessibleLevels: false, includeTags: true)
        case .following:
            page = try await session.mediaPage(filter: key.filter, cursor: cursor, creator: nil, followed: true, includeTags: true)
        case .creator(let creator):
            page = try await session.mediaPage(filter: key.filter, cursor: cursor, creator: creator, followed: false, includeTags: true)
        case .discovery:
            page = try await session.mediaPage(filter: key.filter, cursor: cursor, creator: nil, followed: false, includeTags: true)
        }
        return try await session.enrichVideoDurations(in: page, filter: key.filter) {
            key.identity == session.feedIdentity && (key == self.requestKey || key == self.restartKey)
        }
    }

    /// Rebuilds the feed from cursor nil off to the side, replacing the current
    /// list only after the first visible result (or a confirmed end) is available.
    func restartFromStart(session: any FeedPageReading, filter: FeedFilter, source: FeedSource,
                          blockedTags: Set<String> = []) async -> FeedRestartResult {
        let key = FeedStoreRequestKey(identity: session.feedIdentity, filter: filter, source: source)
        if Task.isCancelled {
            return FeedRestartResult(status: .cancelled, key: key, revision: generation, error: nil)
        }
        if restartRevision != nil {
            if restartKey == key, let restartTask { return await restartTask.value }
            generation += 1
            cancelRestart()
        }
        if restartRetryKey == key, let availableAt = restartRetryAvailableAt, now() < availableAt {
            return FeedRestartResult(status: .failedRetainingPrevious, key: key, revision: generation,
                                     error: restartRetryError ?? "请求暂时无法完成，请稍后重试。")
        }
        if restartRetryKey != key { resetRestartRetry() }
        restartRetryAvailableAt = nil

        generation += 1
        let revision = generation
        cancelPageScan()
        loading = false
        restartPreviousContinuationState = continuationState.isLoading ? .ready : continuationState
        continuationState = .loading
        restartRevision = revision
        restartKey = key
        restartBlockedTags = blockedTags
        let lease = FeedCancellationLease()
        restartLease = lease

        let task = Task { @MainActor [weak self] in
            guard let self else { return FeedRestartResult(status: .superseded, key: key, revision: revision, error: nil) }
            return await self.performRestartFromStart(session: session, key: key, blockedTags: blockedTags,
                                                      assetPolicy: self.currentAssetDeduplicationPolicy,
                                                      revision: revision, lease: lease)
        }
        restartTask = task
        // Only the caller that creates this transaction owns cancellation.
        // Same-key joiners above merely await its result and cannot cancel it.
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            lease.cancel()
            task.cancel()
        }
    }

    private func performRestartFromStart(session: any FeedPageReading, key: FeedStoreRequestKey,
                                         blockedTags: Set<String>, assetPolicy: Bool,
                                         revision: Int, lease: FeedCancellationLease) async -> FeedRestartResult {

        var staged = FeedAccumulator(blockedTags: blockedTags, deduplicateMediaAssets: assetPolicy, videoDurationRange: key.filter.videoDurationRange)
        var stagedCursors = Set<String>()
        var stagedProgress: SearchScanProgress?

        func finish(_ status: FeedRestartResult.Status, error: String? = nil) -> FeedRestartResult {
            if self.restartRevision == revision {
                if status != .committed {
                    self.continuationState = self.restartPreviousContinuationState ?? (self.reachedEnd ? .ended : .ready)
                }
                self.restartRevision = nil
                self.restartKey = nil
                self.restartLease = nil
                self.restartTask = nil
                self.restartBlockedTags = nil
                self.restartPreviousContinuationState = nil
            }
            return FeedRestartResult(status: status, key: key, revision: revision, error: error)
        }

        do {
            var scannedPages = 0
            while true {
                guard restartRevision == revision, restartKey == key,
                      key.identity == session.feedIdentity, !Task.isCancelled, !lease.isCancelled else {
                    return finish(Task.isCancelled || lease.isCancelled ? .cancelled : .superseded)
                }
                let page = try await withTaskCancellationHandler {
                    try await fetchPage(session: session, key: key, cursor: staged.cursor)
                } onCancel: {
                    lease.cancel()
                }
                guard restartRevision == revision, restartKey == key,
                      key.identity == session.feedIdentity, !Task.isCancelled, !lease.isCancelled else {
                    return finish(Task.isCancelled || lease.isCancelled ? .cancelled : .superseded)
                }
                if page.durationEnrichmentFailed {
                    if let status = page.durationEnrichmentHTTPStatus { throw ClientError.http(status) }
                    throw ClientError.format("无法取得视频时长，请稍后重试。")
                }
                staged.applyBlockedTags(restartBlockedTags ?? blockedTags)
                let authorSnapshot = currentAuthorBlocks()
                staged.applyBlockedAuthors(ids: authorSnapshot.ids, handles: authorSnapshot.handles)
                staged.setDeduplicateMediaAssets(currentAssetDeduplicationPolicy)
                stagedProgress = page.searchProgress
                let previousCount = staged.items.count
                staged.append(page, kind: key.filter.effectiveKind)
                if let cursor = staged.cursor, !stagedCursors.insert(cursor).inserted {
                    return finish(.failedRetainingPrevious, error: "加载停滞：站点重复返回分页位置，请重试从头刷新。")
                }
                if staged.items.count > previousCount || staged.reachedEnd { break }
                scannedPages += 1
                continuationState = .scanning
                if scannedPages.isMultiple(of: 4) {
                    // This task is the restart owner, so cancelRestart cancels
                    // its wait as well as the currently awaited source read.
                    try await slicePause(scannedPages / 4)
                } else {
                    await Task.yield()
                }
            }
            guard restartRevision == revision, restartKey == key,
                  key.identity == session.feedIdentity, !Task.isCancelled, !lease.isCancelled else {
                return finish(Task.isCancelled || lease.isCancelled ? .cancelled : .superseded)
            }

            let finalBlockedTags = restartBlockedTags ?? blockedTags
            let finalAuthorSnapshot = currentAuthorBlocks()
            let finalAssetPolicy = currentAssetDeduplicationPolicy
            staged.applyBlockedTags(finalBlockedTags)
            staged.applyBlockedAuthors(ids: finalAuthorSnapshot.ids, handles: finalAuthorSnapshot.handles)
            staged.setDeduplicateMediaAssets(finalAssetPolicy)

            self.filter = key.filter
            self.source = key.source
            self.requestKey = key
            self.blockedTags = finalBlockedTags
            self.deduplicateMediaAssets = finalAssetPolicy
            self.configured = true
            self.accumulator = staged
            self.items = staged.items
            self.reachedEnd = staged.reachedEnd
            self.seenCursors = stagedCursors
            self.searchProgress = stagedProgress
            self.hiddenByTags = staged.blockedCount
            self.hiddenByAuthors = staged.blockedAuthorCount
            self.hiddenByDuration = staged.hiddenByDuration
            self.unverifiedDuration = staged.unverifiedDuration
            self.durationMetadataFailedPages = 0
            self.unverifiedTags = staged.unverifiedCount
            self.duplicatesDiscarded = staged.duplicateCount
            self.error = nil
            self.loading = false
            self.continuationState = staged.reachedEnd ? .ended : .ready
            self.consecutiveRequestFailures = 0
            self.resetRestartRetry()
            self.loadState = staged.reachedEnd ? .ended : (staged.items.isEmpty ? .incomplete : .loaded)
            return finish(.committed)
        } catch is CancellationError {
            return finish(.cancelled)
        } catch {
            guard restartRevision == revision, restartKey == key,
                  key.identity == session.feedIdentity, !Task.isCancelled, !lease.isCancelled else {
                return finish(Task.isCancelled || lease.isCancelled ? .cancelled : .superseded)
            }
            consecutiveRestartFailures = min(6, consecutiveRestartFailures + 1)
            let rateLimited: Bool = if case ClientError.http(429) = error { true } else { false }
            let delay = min(rateLimited ? 30.0 : 8.0, (rateLimited ? 3.0 : 0.5) * pow(2, Double(consecutiveRestartFailures - 1)))
            restartRetryKey = key; restartRetryError = error.localizedDescription
            restartRetryAvailableAt = now().addingTimeInterval(delay)
            return finish(.failedRetainingPrevious, error: error.localizedDescription)
        }
    }

    private func cancelRestart() {
        restartTask?.cancel()
        restartLease?.cancel()
        restartTask = nil
        restartLease = nil
        restartRevision = nil
        restartKey = nil
        restartBlockedTags = nil
        if let previous = restartPreviousContinuationState { continuationState = previous }
        restartPreviousContinuationState = nil
    }

    func accepts(_ commit: FeedCommit, identity: String) -> Bool {
        guard let key = commit.key, key == requestKey, key.identity == identity,
              commit.revision == generation else { return false }
        return commit.status == .committed || commit.status == .unchanged
    }

    func reconcileFollowing(_ ids: Set<Int>, current: Int?) {
        guard source == .following else { return }
        resetRestartRetry()
        generation += 1; cancelRestart(); cancelPageScan(); loading = false; error = nil; loadState = .incomplete
        continuationState = .ready; consecutiveRequestFailures = 0
        accumulator.retainFollowing(ids, current: current)
        if !tagPolicyDeferred { accumulator.applyBlockedTags(blockedTags) }
        seenCursors = []
        items = accumulator.items; reachedEnd = false
        hiddenByDuration = accumulator.hiddenByDuration; unverifiedDuration = accumulator.unverifiedDuration
        hiddenByTags = accumulator.blockedCount; unverifiedTags = accumulator.unverifiedCount; duplicatesDiscarded = accumulator.duplicateCount
        hiddenByAuthors = accumulator.blockedAuthorCount
    }

    /// Cursor can be retained only when the saved segment contains the actual tail
    /// of every accumulated source row, including rows hidden by local policies.
    func continuationSnapshot(windowIDs: [Int], capturedAt: Date = Date()) -> TimelineContinuation? {
        guard TimelineStatePolicy.continuationCoversLoadedTail(windowIDs: windowIDs, sourceTailID: accumulator.sourceTailID) else { return nil }
        return TimelineContinuation(cursor: accumulator.cursor, capturedAt: capturedAt, reachedEnd: accumulator.reachedEnd)
    }

    func invalidatePendingRequests() {
        generation += 1; cancelRestart(); cancelPageScan(); loading = false
        if continuationState.isLoading { continuationState = reachedEnd ? .ended : .ready }
    }

    func restoreTimeline(items restored: [MediaItem], identity: String, filter: FeedFilter, followed: Bool,
                         continuation: TimelineContinuation?, blockedTags: Set<String>, rescanBoundaryID: Int? = nil) {
        resetRestartRetry()
        generation += 1; cancelRestart()
        self.filter = filter; self.source = followed ? .following : .discovery; self.blockedTags = blockedTags
        deduplicateMediaAssets = currentAssetDeduplicationPolicy
        requestKey = FeedStoreRequestKey(identity: identity, filter: filter, source: source)
        activationPendingRevision = nil
        cancelPageScan()
        loadState = continuation?.reachedEnd == true ? .ended : (restored.isEmpty ? .incomplete : .loaded)
        configured = true; tagPolicyDeferred = false
        accumulator = FeedAccumulator(blockedTags: blockedTags, deduplicateMediaAssets: deduplicateMediaAssets, videoDurationRange: filter.videoDurationRange)
        accumulator.restore(restored, cursor: continuation?.cursor, reachedEnd: continuation?.reachedEnd ?? false,
                            rescanFromBeginning: continuation == nil, rescanBoundaryID: rescanBoundaryID)
        let authorSnapshot = currentAuthorBlocks()
        accumulator.applyBlockedAuthors(ids: authorSnapshot.ids, handles: authorSnapshot.handles)
        items = accumulator.items; loading = false; activePageTask = nil; activePageLease = nil; error = nil
        reachedEnd = accumulator.reachedEnd
        continuationState = reachedEnd ? .ended : .ready; consecutiveRequestFailures = 0
        hiddenByDuration = accumulator.hiddenByDuration; unverifiedDuration = accumulator.unverifiedDuration
        hiddenByTags = accumulator.blockedCount; unverifiedTags = accumulator.unverifiedCount
        hiddenByAuthors = accumulator.blockedAuthorCount; duplicatesDiscarded = accumulator.duplicateCount
        searchProgress = nil
        seenCursors = continuation?.cursor.map { Set([$0]) } ?? []
    }

    /// Safe fallback for legacy/truncated checkpoints: seed seen works, then restart
    /// at the upstream beginning so no uncovered segment is silently skipped.
    func restartContinuation() {
        generation += 1; cancelRestart(); cancelPageScan(); loading = false; error = nil
        accumulator.restartContinuation(); reachedEnd = false; seenCursors = []
        continuationState = .ready; consecutiveRequestFailures = 0
    }
}
