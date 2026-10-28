import Foundation
import Combine

/// Owns timeline presentation, restore transactions and focus commits. FeedStore
/// owns generic result requests; the View owns only controls and navigation.
@MainActor final class TimelineModel: ObservableObject {
    let followed: Bool
    let feed: FeedStore
    let history: BrowsingHistory
    private let authors: AuthorBlocklist
    private let dismissals: TimelineCheckpointDismissals
    @Published private(set) var filter: FeedFilter
    @Published var focused: Int? {
        didSet { if focused != returnedToTopID { returnedToTopID = nil } }
    }
    @Published private(set) var focusRequest = 0
    @Published private(set) var queueRevision = 0
    @Published private(set) var restoreState: TimelineRestoreState = .browsing
    @Published private(set) var notice: TimelineNotice?
    @Published private(set) var pagingMode = TimelinePagingMode.automatic
    @Published private(set) var promptRevision = 0
    private var visible = false
    private var ownerID: Int?
    private var operationRevision = 0
    private var blockedTags = Set<String>()
    private var observations = Set<AnyCancellable>()
    private var noticeExpiry: Task<Void, Never>?
    private var restoreRead: Task<[MediaItem], Error>?
    private var restoreReadID: UUID?
    private var restartAction: Task<Void, Never>?
    private var returnedToTopID: Int?
    private var fillTask: Task<Void, Never>?
    private var fillID: UUID?
    private var fillMinimumUpcoming = 0

    init(followed: Bool, filter: FeedFilter? = nil, feed: FeedStore? = nil,
         history: BrowsingHistory? = nil, authors: AuthorBlocklist? = nil,
         dismissals: TimelineCheckpointDismissals = TimelineCheckpointDismissals()) {
        self.followed = followed
        self.filter = filter ?? FeedFilter.saved(followed: followed)
        let authors = authors ?? .shared
        self.authors = authors
        self.feed = feed ?? FeedStore(diagnostics: .shared, authorBlocks: authors)
        self.history = history ?? .shared
        self.dismissals = dismissals
        self.feed.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        self.history.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        authors.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
    }
    var source: FeedSource { followed ? .following : .discovery }
    var lane: HistoryLane { followed ? .following : .recommendation }
    var message: String? { notice?.text }
    var messageIsError: Bool { notice?.isError == true }
    var automaticLoadingAllowed: Bool {
        !restoreState.isBusy && pagingMode == .automatic && (returnedToTopID == nil || focused != returnedToTopID)
    }
    /// Appearance may fill an ordinary browsing queue, but restored queues
    /// remain explicitly page-gated until the user continues them.
    var shouldFillOnAppearance: Bool {
        visible && restoreState == .browsing && automaticLoadingAllowed && !feed.reachedEnd &&
            feed.continuationState.failure == nil
    }
    var context: HistoryContext? { history.context(ownerID: ownerID) }
    var resumeCandidate: TimelineCheckpoint? {
        guard !restoreState.isBusy, let context,
              let checkpoint = history.resumeOffer(for: lane, context: context),
              !dismissals.contains(owner: context.ownerKey, lane: lane, checkpoint: checkpoint) else { return nil }
        return checkpoint
    }
    var resumePositions: [Int: Double] {
        guard let checkpoint = restoreState.checkpoint else { return [:] }
        return Dictionary(uniqueKeysWithValues: checkpoint.ids.compactMap { id in history.resumePosition(for: id).map { (id, $0) } })
    }
    func bindHistory(ownerID: Int?) {
        guard self.ownerID != ownerID else { return }
        self.ownerID = ownerID; restartAction?.cancel(); invalidateOperation()
        restoreState = .browsing; pagingMode = .automatic; clearMessage(); focused = nil; feed.clear()
    }
    func setVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value
        if !value {
            restartAction?.cancel(); invalidateOperation(); feed.invalidatePendingRequests()
            if restoreState.isBusy { restoreState = .browsing }
            if notice?.isError == false { clearMessage() }
        }
    }
    func selectFilter(_ value: FeedFilter) {
        guard value != filter else { return }
        restartAction?.cancel(); invalidateOperation(); filter = value
        restoreState = .browsing; pagingMode = .automatic; clearMessage(); focused = nil; feed.clear()
    }
    func invalidateSession() {
        restartAction?.cancel(); invalidateOperation(); restoreState = .browsing; pagingMode = .automatic; clearMessage(); focused = nil; feed.clear()
    }
    func applyBlockedTags(_ names: Set<String>) {
        if blockedTags != names { invalidateFill() }
        blockedTags = names; feed.applyBlockedTags(names)
    }
    func dismissPrompt() {
        guard let checkpoint = resumeCandidate, let context else { return }
        dismissals.dismiss(owner: context.ownerKey, lane: lane, checkpoint: checkpoint)
        promptRevision += 1
    }
    func clearMessage(id: UUID? = nil) {
        guard id == nil || notice?.id == id else { return }
        noticeExpiry?.cancel(); noticeExpiry = nil; notice = nil
    }
    func checkpoint(for item: MediaItem) -> TimelineCheckpoint? {
        guard var checkpoint = TimelineCheckpoint.window(lane: lane, filter: filter, items: feed.items, focusedID: item.id) else { return nil }
        checkpoint.continuation = feed.continuationSnapshot(windowIDs: checkpoint.ids)
        return checkpoint
    }
    func activate(session: any TimelineReading, visible: Bool, blockedTags: Set<String>, force: Bool = false) async {
        guard !Task.isCancelled else { return }
        setVisible(visible); bindHistory(ownerID: session.tagLibraryOwnerID)
        applyBlockedTags(blockedTags)
        guard visible, !restoreState.isBusy, !followed || session.account != nil else { return }
        let target = FeedStoreRequestKey(identity: session.feedIdentity, filter: filter, source: source)
        // A normal appearance must not retry a failed restart, even when the
        // retained store was incomplete or had not configured its first key yet.
        if !force, pagingMode.waitingKey == target { return }
        if feed.requestKey != target || force || pagingMode.isWaitingForExplicitAction {
            invalidateOperation(); restoreState = .browsing; pagingMode = .automatic; clearMessage(); focused = nil
        }
        let revision = operationRevision
        let commit = await feed.activate(session: session, filter: filter, source: source, blockedTags: blockedTags, force: force)
        guard !Task.isCancelled, self.visible, revision == operationRevision,
              feed.accepts(commit, identity: session.feedIdentity) else { return }
        if focused == nil { focused = feed.items.first?.id }
    }
    func followingChanged(_ ids: Set<Int>, session: any TimelineReading) async {
        guard !Task.isCancelled, followed, ids == session.followingMemberIDs else { return }
        restartAction?.cancel(); invalidateOperation(); restoreState = .browsing; pagingMode = .automatic; clearMessage()
        feed.reconcileFollowing(ids, current: focused)
        if visible { await next(session: session) }
    }
    func next(session: any TimelineReading) async {
        guard !Task.isCancelled, visible, !restoreState.isBusy, !restoreState.continuationUnavailable else { return }
        returnedToTopID = nil
        // The deck does not call this automatically while paused after a failed
        // restart. An explicit continue/retry action can resume the old queue.
        pagingMode = .automatic
        await loadNext(session: session, automatic: false)
    }
    /// A user's continuation gesture resumes a saved queue and fills its media
    /// window. Ordinary grid pagination and appearance gates remain separate.
    func nextAndFillUpcoming(session: any TimelineReading, minimumUpcoming: Int = 6) async {
        let revision = operationRevision, identity = session.feedIdentity
        await next(session: session)
        guard !Task.isCancelled, visible, revision == operationRevision, identity == session.feedIdentity else { return }
        await fillUpcoming(session: session, minimumUpcoming: minimumUpcoming)
    }
    /// The automatic path never clears an explicit-wait or programmatic-top
    /// gate. UI prefetch/near-tail demand must use this instead of explicit next.
    func nextAutomatically(session: any TimelineReading) async {
        guard !Task.isCancelled, visible, automaticLoadingAllowed,
              !restoreState.continuationUnavailable, feed.canAutomaticallyContinue else { return }
        await loadNext(session: session, automatic: true)
    }

    /// Coalesces UI demand into one model-owned fill operation. Cancelling an
    /// individual view waiter does not cancel the shared owner; lifecycle and
    /// query changes invalidate it through `invalidateFill`. Appearance callers
    /// must check `shouldFillOnAppearance`; explicit near-tail demand may also
    /// continue an already restored queue after the user has paged it.
    func fillUpcoming(session: any TimelineReading, minimumUpcoming: Int = 6) async {
        guard !Task.isCancelled, canFillUpcoming else { return }
        let reserve = min(12, max(1, minimumUpcoming))
        let id: UUID
        let task: Task<Void, Never>
        if let currentID = fillID, let currentTask = fillTask {
            fillMinimumUpcoming = max(fillMinimumUpcoming, reserve)
            id = currentID; task = currentTask
        } else {
            guard feed.canAutomaticallyContinue else { return }
            id = UUID(); fillID = id
            fillMinimumUpcoming = reserve
            let revision = operationRevision
            let identity = session.feedIdentity
            let selectedFilter = filter
            let source = self.source
            task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.runFillUpcoming(id: id, session: session,
                                           revision: revision, identity: identity,
                                           filter: selectedFilter, source: source)
            }
            fillTask = task
        }
        await task.value
    }

    private func runFillUpcoming(id: UUID, session: any TimelineReading,
                                 revision: Int, identity: String, filter selectedFilter: FeedFilter,
                                 source selectedSource: FeedSource) async {
        defer {
            if fillID == id { fillID = nil; fillTask = nil; fillMinimumUpcoming = 0 }
        }
        func isCurrent() -> Bool {
            !Task.isCancelled && fillID == id && visible && operationRevision == revision &&
                session.feedIdentity == identity && filter == selectedFilter && source == selectedSource &&
                canFillUpcoming
        }
        while isCurrent() {
            guard upcomingCount() < fillMinimumUpcoming, !feed.reachedEnd,
                  feed.continuationState.failure == nil, feed.canAutomaticallyContinue else { return }
            let existingIDs = Set(feed.items.map(\.id))
            await loadNext(session: session, automatic: true)
            guard isCurrent() else { return }
            if feed.items.allSatisfy({ existingIDs.contains($0.id) }) { return }
            // `loadNext` publishes each accepted page immediately. Re-read the
            // queue and current focus before deciding whether another page helps.
        }
    }

    private func upcomingCount() -> Int {
        guard !feed.items.isEmpty else { return 0 }
        let focusIndex = focused.flatMap { id in feed.items.firstIndex(where: { $0.id == id }) } ?? 0
        guard focusIndex + 1 < feed.items.count else { return 0 }
        return Set(feed.items[(focusIndex + 1)...].map(\.id)).count
    }

    private var canFillUpcoming: Bool {
        visible && !restoreState.isBusy && automaticLoadingAllowed && !restoreState.continuationUnavailable
    }

    private func invalidateFill() {
        fillTask?.cancel(); fillTask = nil; fillID = nil; fillMinimumUpcoming = 0
    }
    private func loadNext(session: any TimelineReading, automatic: Bool) async {
        let revision = operationRevision
        if case .resumed(let checkpoint, .rescanPending) = restoreState {
            feed.restartContinuation(); restoreState = .resumed(checkpoint, .rescanning)
        }
        let commit = automatic ? await feed.nextAutomatically(session: session) : await feed.next(session: session)
        guard !Task.isCancelled, visible, revision == operationRevision,
              feed.accepts(commit, identity: session.feedIdentity) else { return }
        if case .resumed(let checkpoint, .savedCursor) = restoreState, feed.error != nil {
            restoreState = .resumed(checkpoint, .unavailable)
            show("保存的续页位置失效或暂时无法读取。当前已恢复作品仍保留；可选择重新获取当前结果。", error: true)
        }
        if focused == nil { focused = feed.items.first?.id }
    }
    func restore(_ checkpoint: TimelineCheckpoint, session: any TimelineReading) async {
        guard !Task.isCancelled, visible, !restoreState.isBusy, checkpoint.lane == lane,
              let context, history.accepts(context), !followed || session.account != nil,
              let offered = resumeCandidate,
              TimelineStatePolicy.dismissalSignature(owner: context.ownerKey, lane: lane, checkpoint: offered) ==
                TimelineStatePolicy.dismissalSignature(owner: context.ownerKey, lane: lane, checkpoint: checkpoint) else { return }
        let token = UUID()
        invalidateOperation()
        let revision = operationRevision, identity = session.feedIdentity
        let initialFilter = filter, following = session.followingMemberIDs
        // Consumed at click, including failure. Preserve the checkpoint/history,
        // but never resurrect this offer on a redraw or process reconstruction.
        dismissals.dismiss(owner: context.ownerKey, lane: lane, checkpoint: checkpoint)
        promptRevision += 1; restoreState = .restoring(token); pagingMode = .automatic; clearMessage()
        feed.invalidatePendingRequests()
        func current() -> Bool {
            !Task.isCancelled && visible && operationRevision == revision && restoreState == .restoring(token) &&
                filter == initialFilter && session.feedIdentity == identity && history.accepts(context) &&
                (!followed || session.followingMemberIDs == following)
        }
        defer { if restoreState == .restoring(token) { restoreState = .browsing } }
        do {
            let readID = UUID()
            let read = Task {
                let items = try await session.resumeMediaItems(ids: checkpoint.ids, followingIDs: followed ? following : nil, isCurrent: current)
                return try await session.enrichRestoredVideoDurations(items, filter: checkpoint.filter, isCurrent: current)
            }
            restoreReadID = readID; restoreRead = read
            defer { if restoreReadID == readID { restoreReadID = nil; restoreRead = nil } }
            let received = try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
            guard current() else { return }
            let allowed = HistoryMediaPolicy.ordered(received, ids: checkpoint.ids, blockedTags: blockedTags,
                filter: checkpoint.filter, followingIDs: followed ? following : nil,
                allowedMask: session.account?.browsingLevel ?? 1).filter { !authors.blocks($0) }
            guard allowed.contains(where: { $0.id == checkpoint.focusedID }) else {
                show("上次焦点作品当前无法核验或不再符合账号、筛选与屏蔽范围，原时间线已保留。", error: true)
                return
            }
            guard current() else { return }
            filter = checkpoint.filter
            feed.restoreTimeline(items: allowed, identity: identity, filter: checkpoint.filter, followed: followed,
                                 continuation: checkpoint.continuation, blockedTags: blockedTags, rescanBoundaryID: checkpoint.ids.last)
            focused = checkpoint.focusedID; focusRequest += 1
            let continuation: TimelineContinuationMode = checkpoint.continuation?.cursor != nil ? .savedCursor :
                (checkpoint.continuation == nil ? .rescanPending : .rescanning)
            restoreState = .resumed(checkpoint, continuation)
            if checkpoint.continuation == nil {
                show("已恢复保存的片段；继续加载将从当前结果起点重新取得作品，并跳过已恢复记录。", error: false)
            }
        } catch is CancellationError {} catch {
            guard current() else { return }
            show("无法恢复上次时间线：\(error.localizedDescription)；原时间线与焦点已保留。", error: true)
        }
    }
    /// Re-selecting the tab moves within the existing queue without changing
    /// its filter, continuation, pending recovery or already loaded works.
    func scrollToStart() {
        guard visible, !restoreState.isBusy, let first = feed.items.first?.id else { return }
        invalidateFill()
        returnedToTopID = first
        focused = first
        focusRequest += 1
    }

    /// UI events are coalesced here so another double tap does not cancel the
    /// structured waiter that must commit the new focus and playback identity.
    func requestRestartFromStart(session: any TimelineReading) {
        guard visible, !restoreState.isRefreshing else { return }
        bindHistory(ownerID: session.tagLibraryOwnerID)
        restartAction?.cancel()
        restartAction = Task { [weak self] in await self?.restartFromStart(session: session) }
    }
    func restartFromStart(session: any TimelineReading) async {
        guard !Task.isCancelled, visible, !restoreState.isRefreshing,
              !followed || session.account != nil else { return }
        bindHistory(ownerID: session.tagLibraryOwnerID)
        // Starting over consumes the old offer, without removing its history.
        dismissPrompt()
        let previousState: TimelineRestoreState = restoreState.isRestoring ? .browsing : restoreState
        let token = UUID()
        invalidateOperation()
        let revision = operationRevision, identity = session.feedIdentity, targetFilter = filter
        restoreState = .refreshing(token); clearMessage()
        feed.invalidatePendingRequests()
        defer { if restoreState == .refreshing(token) { restoreState = previousState } }
        let result = await feed.restartFromStart(session: session, filter: targetFilter, source: source, blockedTags: blockedTags)
        guard !Task.isCancelled, visible, operationRevision == revision, restoreState == .refreshing(token),
              identity == session.feedIdentity, filter == targetFilter else { return }
        switch result.status {
        case .committed:
            restoreState = .browsing; pagingMode = .automatic
            focused = feed.items.first?.id; focusRequest += 1; queueRevision += 1
            let text = feed.items.isEmpty ? (feed.reachedEnd ? "当前条件没有作品。" : "已回到当前条件起点，暂未找到匹配作品，可继续加载。") : "已按当前条件从第一条重新开始。"
            show(text, error: false)
        case .failedRetainingPrevious:
            restoreState = previousState; pagingMode = .waitingForExplicitAction(result.key)
            show("从头刷新失败：\(result.error ?? "暂时无法取得作品")；原播放队列和浏览位置已保留。", error: true, recovery: .restartFromStart)
        case .unchanged, .superseded, .cancelled:
            break
        }
    }

    private func invalidateOperation() {
        invalidateFill()
        returnedToTopID = nil
        operationRevision += 1
        restoreRead?.cancel(); restoreRead = nil; restoreReadID = nil
    }

    private func show(_ text: String, error: Bool, recovery: TimelineNotice.Recovery? = nil) {
        noticeExpiry?.cancel()
        let event = TimelineNotice(text: text, severity: error ? .error : .information, recovery: recovery)
        notice = event
        guard !error else { noticeExpiry = nil; return }
        // This timer belongs to one event, not a rendered view or page exposure.
        noticeExpiry = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(2500)); try Task.checkCancellation() } catch { return }
            guard let self, self.notice?.id == event.id, self.notice?.isError == false else { return }
            self.clearMessage(id: event.id)
        }
    }
}
