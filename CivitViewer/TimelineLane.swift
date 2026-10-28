import SwiftUI
import UIKit

private struct TimelineGestureFrameKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value.append(contentsOf: nextValue()) }
}

private extension View {
    func timelineGestureFrame(in space: Namespace.ID) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: TimelineGestureFrameKey.self, value: [geometry.frame(in: .named(space))])
        })
    }
}

struct TimelineLane: View {
    var isVisible: Bool
    let followed: Bool
    var presentation: TimelinePresentation = .stream
    var restartRequest = 0
    var topRequest = 0
    @EnvironmentObject private var session: SiteSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.ordinaryColorScheme) private var ordinaryColorScheme
    @Environment(\.viewingBottomBarHeight) private var bottomBarHeight
    @ObservedObject private var blocklist = TagBlocklist.shared
    @ObservedObject private var history = BrowsingHistory.shared
    @ObservedObject private var chrome = ViewingChromeController.shared
    @AppStorage("mediaPrefetchCount") private var mediaPrefetchCount = 6
    @StateObject private var model: TimelineModel
    @State private var showFilter = false
    @State private var filterChromeScope = UUID()
    @State private var creator: CreatorRoute?
    @State private var navigationVisible = true
    @State private var kindDrag = 0.0
    @State private var kindDragReady = false
    @State private var handledRestartRequest = 0
    @State private var handledTopRequest = 0
    @State private var gridAnchor: Int?
    @State private var gridViewer: MediaItem?
    @Namespace private var gestureSpace
    @State private var overlayFrames: [CGRect] = []
    @State private var continuationAction: Task<Void, Never>?
    @State private var continuationActionID: UUID?
    private var laneVisible: Bool { isVisible && (navigationVisible || gridViewer != nil) }
    private var preloadReserve: Int { max(6, [3, 6, 10].contains(mediaPrefetchCount) ? mediaPrefetchCount : 6) }
    private var continuationState: FeedContinuationState {
        if model.restoreState.continuationUnavailable {
            return .failed(.stalled(message: "保存的续页位置当前不可用；原作品仍保留，请重新获取当前结果。"))
        }
        return feed.continuationState
    }
    #if DEBUG && targetEnvironment(simulator)
    @State private var qaMediaActive = false
    #endif
    #if DEBUG && targetEnvironment(simulator)
    private let qaController: ResumePromptQAController?
    #endif
    private struct LoadKey: Equatable {
        let visible: Bool
        let request: FeedStoreRequestKey
        let restoring: Bool
    }
    private var feed: FeedStore { model.feed }
    private var chromeHeight: CGFloat { verticalSizeClass == .compact ? 92 : 104 }
    private var floatingHeader: Bool {
        presentation == .stream && deckIsVisible && !feed.items.isEmpty &&
        feed.requestKey?.identity == session.feedIdentity && !(followed && session.account == nil)
    }
    private var filter: FeedFilter { model.filter }
    private var lane: HistoryLane { model.lane }
    private var historyContext: HistoryContext? { history.context(ownerID: session.tagLibraryOwnerID) }
    private var loadKey: LoadKey {
        .init(visible: laneVisible && scenePhase == .active,
              request: .init(identity: session.feedIdentity, filter: filter, source: model.source),
              restoring: model.restoreState.isBusy)
    }
    private var filterBinding: Binding<FeedFilter> { .init(get: { model.filter }, set: model.selectFilter) }
    private var kindBinding: Binding<MediaKind> {
        .init(get: { filter.effectiveKind }, set: { model.selectFilter(filter.selecting(kind: $0)) })
    }
    private var tagSummary: String {
        let tags = blocklist.names.isEmpty ? "" : "标签屏蔽隐藏 \(feed.hiddenByTags) 项，另有 \(feed.unverifiedTags) 项标签待核实、暂不展示。"
        let duration = filter.videoDurationRange == nil ? "" : "时长范围隐藏 \(feed.hiddenByDuration) 项；\(feed.unverifiedDuration) 项时长未知，暂不展示。仅覆盖已查结果，可继续加载。"
        return tags + duration
    }
    private var draggedKind: MediaKind? {
        guard abs(kindDrag) > 5, let index = MediaKind.allCases.firstIndex(of: filter.effectiveKind) else { return nil }
        let next = index + (kindDrag < 0 ? 1 : -1)
        return MediaKind.allCases.indices.contains(next) ? MediaKind.allCases[next] : nil
    }
    init(isVisible: Bool, followed: Bool, presentation: TimelinePresentation = .stream, restartRequest: Int = 0, topRequest: Int = 0) {
        self.isVisible = isVisible; self.followed = followed; self.presentation = presentation; self.restartRequest = restartRequest; self.topRequest = topRequest
        #if DEBUG && targetEnvironment(simulator)
        self.qaController = nil
        #endif
        #if DEBUG && targetEnvironment(simulator)
        _model = StateObject(wrappedValue: TimelineModel(followed: followed,
            filter: AutoContinuationQA.enabled ? AutoContinuationQA.filter : nil,
            dismissals: ViewportAuditQA.enabled ? ViewportAuditQA.dismissals() : TimelineCheckpointDismissals()))
        #else
        _model = StateObject(wrappedValue: TimelineModel(followed: followed))
        #endif
    }
    #if DEBUG && targetEnvironment(simulator)
    init(isVisible: Bool, followed: Bool, presentation: TimelinePresentation = .stream, restartRequest: Int = 0, topRequest: Int = 0, qaController: ResumePromptQAController?) {
        self.isVisible = isVisible; self.followed = followed; self.presentation = presentation; self.restartRequest = restartRequest; self.topRequest = topRequest; self.qaController = qaController
        _model = StateObject(wrappedValue: TimelineModel(followed: followed,
            filter: AutoContinuationQA.enabled ? AutoContinuationQA.filter : nil,
            dismissals: qaController == nil ? (ViewportAuditQA.enabled ? ViewportAuditQA.dismissals() : TimelineCheckpointDismissals()) : ResumePromptQA.dismissals()))
    }
    #endif

    var body: some View {
        ZStack(alignment: .top) {
            if presentation == .stream && !feed.items.isEmpty { Color.black }
            else { Color(uiColor: .systemBackground) }
            if followed && session.account == nil {
                ContentUnavailableView { Label("登录后刷关注作品", systemImage: "person.2") } description: {
                    Text("查看你在 Civitai 关注的作者发布的图片和视频。")
                } actions: { Button("使用 Google 登录") { session.openLogin() }.buttonStyle(AppActionButtonStyle(tone: .accent)) }
            } else if feed.requestKey?.identity == session.feedIdentity && !feed.items.isEmpty {
                if presentation == .grid {
                    MediaGrid(feed: feed, continuationState: continuationState, emptyDescription: filter.summary,
                              adjustFilter: { showFilter = true }, anchor: $gridAnchor,
                              scrollRequest: model.focusRequest + model.queueRevision, loadsOnAppearance: false,
                              isVisible: deckIsVisible && gridViewer == nil,
                              automaticLoadingAllowed: model.automaticLoadingAllowed,
                              loadMoreAutomatically: { await model.nextAutomatically(session: session) },
                              refreshFromStart: { await model.restartFromStart(session: session) }) { item in
                        model.focused = item.id; gridViewer = item
                    } loadMore: { await model.next(session: session) }
                        .padding(.top, chromeHeight + 4)
                } else {
                MediaDeck(items: feed.items, focused: $model.focused, focusRequest: model.focusRequest,
                          queueRevision: model.queueRevision, playbackSuspended: model.restoreState.isRefreshing,
                          automaticLoadingAllowed: model.automaticLoadingAllowed, loadsPageOnAppearance: false,
                          isVisible: deckIsVisible,
                          continuationState: continuationState,
                          loadMoreAutomatically: { await model.fillUpcoming(session: session, minimumUpcoming: preloadReserve) },
                          refreshFromStart: { await model.restartFromStart(session: session) },
                          restartRetryAvailableAt: feed.restartRetryAvailableAt,
                          bottomBarInset: bottomBarHeight,
                          continuationTopInset: chromeHeight,
                          gestureTopExclusion: chrome.hidden ? 0 : chromeHeight,
                          gestureExcludedFrames: chrome.hidden ? [] : overlayFrames,
                          onKindSwipe: changeKind, onKindDrag: dragKind, onAuthor: { creator = $0 }, onDetailsVisibility: { feed.setTagPolicyDeferred($0) },
                          historyCheckpoint: model.checkpoint, resumePositions: model.resumePositions) {
                    await model.nextAndFillUpcoming(session: session, minimumUpcoming: preloadReserve)
                }
                .offset(x: kindDrag * (draggedKind == nil ? 0.08 : 0.45))
                .scaleEffect(1 - min(abs(kindDrag) / 160, 1) * 0.018)
                }
            } else {
                VStack(spacing: 14) {
                    FeedContinuationStatusView(state: continuationState, empty: true,
                        performing: continuationAction != nil,
                        restartRetryAvailableAt: feed.restartRetryAvailableAt,
                        retry: { startContinuationAction { await model.next(session: session) } },
                        restart: { startContinuationAction { await model.restartFromStart(session: session) } },
                        adjust: { showFilter = true })
                    Text(filter.summary + "。" + tagSummary).font(.caption).foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let target = draggedKind {
                HStack(spacing: 8) {
                    if kindDrag > 0 { Image(systemName: "chevron.left") }
                    VStack(spacing: 4) {
                        Text(target.title).font(.headline)
                        Text(kindDragReady ? "松开切换" : "继续拖动").font(.caption2)
                    }
                    if kindDrag < 0 { Image(systemName: "chevron.right") }
                }.foregroundStyle(.white).padding(.horizontal, 15).padding(.vertical, 13)
                    .background(.black.opacity(0.78), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(kindDragReady ? 0.65 : 0.2)))
                    .scaleEffect(kindDragReady ? 1.05 : 0.92)
                    .opacity(min(1, abs(kindDrag) / 30))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: kindDrag < 0 ? .trailing : .leading)
                    .padding(.horizontal, 18).allowsHitTesting(false).transition(.opacity).viewingChromeHidden(chrome.hidden)
            }
            HStack(spacing: 15) {
                Color.clear.frame(width: 44, height: 44).allowsHitTesting(false).accessibilityHidden(true)
                Picker("媒体类型", selection: kindBinding) { ForEach(MediaKind.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).frame(maxWidth: 245)
                .environment(\.colorScheme, floatingHeader ? .dark : ordinaryColorScheme)
                .accessibilityIdentifier(isVisible ? "timeline.media-kind" : "inactive.timeline.media-kind")
                .accessibilityHidden(!isVisible)
                Button { showFilter = true } label: { Image(systemName: "line.3.horizontal.decrease").font(.body).frame(width: 44, height: 44) }
                    .accessibilityLabel("时间线筛选")
                    .accessibilityIdentifier(isVisible ? "timeline.filter" : "inactive.timeline.filter")
                }
                .frame(maxWidth: .infinity)
                #if DEBUG && targetEnvironment(simulator)
                .background(GeometryReader { geometry in
                    if VisualControlsQA.enabled && isVisible {
                        let frame = geometry.frame(in: .global)
                        let rowValue = "x=\(frame.minX);y=\(frame.minY);w=\(frame.width);h=\(frame.height)"
                        let filterValue = "kind=\(filter.effectiveKind.rawValue);sort=\(filter.sort);period=\(filter.period);model=\(filter.baseModel);pg=\(filter.onlyPG)"
                        VStack {
                        Text(rowValue)
                            .font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                            .accessibilityIdentifier("qa.controls.row").accessibilityValue(rowValue)
                        Text(filterValue)
                            .font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                            .accessibilityIdentifier("qa.controls.filter").accessibilityValue(filterValue)
                        }
                    }
                }.allowsHitTesting(false))
                #endif
                .padding(.horizontal, AppTheme.spacing).frame(height: 44).padding(.top, 44)
                .frame(maxWidth: .infinity).padding(.bottom, verticalSizeClass == .compact ? 4 : 16)
                .foregroundStyle(floatingHeader ? Color.white : Color.primary)
                .shadow(color: .black.opacity(floatingHeader ? 0.55 : 0), radius: 2, y: 1)
                .background(floatingHeader ? Color.clear : Color(uiColor: .systemBackground))
                .viewingChromeHidden(chrome.hidden)
            if let savedCheckpoint = model.resumeCandidate {
                HStack(spacing: 8) {
                    Button { Task { await model.restore(savedCheckpoint, session: session) } } label: {
                        Label("接着看 · 上次" + lane.title, systemImage: "play.circle")
                            .font(.caption.weight(.medium)).padding(.horizontal, 13).padding(.vertical, 9)
                    }.disabled(model.restoreState.isBusy).accessibilityIdentifier("timeline.resume")
                    Button { model.dismissPrompt() } label: {
                        Image(systemName: "xmark").font(.caption.weight(.bold)).frame(width: 44, height: 44)
                    }.accessibilityLabel("关闭接着看提示").accessibilityIdentifier("timeline.resume.close")
                }.foregroundStyle(.white).background(.black.opacity(0.68), in: Capsule())
                    .timelineGestureFrame(in: gestureSpace).padding(.top, chromeHeight - 2).viewingChromeHidden(chrome.hidden)
            }
            if let notice = model.notice {
                HStack(spacing: 10) {
                    Text(notice.text).font(.caption).lineLimit(notice.isError ? 5 : 3)
                        .accessibilityIdentifier("timeline.notice.text")
                    if notice.recovery == .restartFromStart {
                        SwiftUI.TimelineView(.periodic(from: .now, by: 0.5)) { context in
                            Button("重试") { model.requestRestartFromStart(session: session) }
                                .font(.caption.weight(.semibold)).frame(minWidth: 44, minHeight: 44)
                                .disabled(model.restoreState.isRefreshing || (feed.restartRetryAvailableAt.map { $0 > context.date } ?? false))
                                .accessibilityIdentifier("timeline.notice.retry")
                        }.fixedSize()
                    }
                    Button { model.clearMessage(id: notice.id) } label: {
                        Image(systemName: "xmark").font(.caption.weight(.bold)).frame(width: 44, height: 44)
                    }.accessibilityLabel("关闭提示").accessibilityIdentifier("timeline.notice.close")
                }.padding(.leading, 12).padding(.trailing, 2).padding(.vertical, 4)
                    .foregroundStyle(.white).background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { if !notice.isError { model.clearMessage(id: notice.id) } })
                    .accessibilityElement(children: .contain).accessibilityIdentifier("timeline.notice")
                    .accessibilityValue(notice.isError ? "错误，等待处理" : "约两秒半后收起，可点按关闭")
                    .timelineGestureFrame(in: gestureSpace)
                    .padding(.horizontal, 16).padding(.top, 102).viewingChromeHidden(chrome.hidden)
            }
            if model.restoreState.isRefreshing {
                HStack(spacing: 9) { ProgressView().tint(.white); Text("正在按当前条件从头刷新…").font(.caption) }
                    .padding(13).foregroundStyle(.white).background(.black.opacity(0.8), in: Capsule())
                    .timelineGestureFrame(in: gestureSpace)
                    .padding(.top, 102).accessibilityIdentifier("timeline.restart.loading").viewingChromeHidden(chrome.hidden)
            }
        }
        .coordinateSpace(name: gestureSpace)
        .onPreferenceChange(TimelineGestureFrameKey.self) { overlayFrames = $0 }
        .clipped().toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showFilter, onDismiss: { chrome.resume(after: filterChromeScope) }) { FilterView(filter: filterBinding, context: followed ? .following : .discovery).presentationDetents([.medium, .large]) }
        .onChange(of: showFilter) { _, shown in
            if shown { chrome.suspend(for: filterChromeScope) }
            else { chrome.resume(after: filterChromeScope) }
        }
        .fullScreenCover(item: $gridViewer) { opening in
            FeedMediaViewer(items: feed.items, focused: $model.focused, initialID: opening.id,
                            focusRequest: model.focusRequest, queueRevision: model.queueRevision,
                            playbackSuspended: model.restoreState.isRefreshing, automaticLoadingAllowed: model.automaticLoadingAllowed,
                            continuationState: continuationState,
                          loadMoreAutomatically: { await model.fillUpcoming(session: session, minimumUpcoming: preloadReserve) },
                            refreshFromStart: { await model.restartFromStart(session: session) },
                            restartRetryAvailableAt: feed.restartRetryAvailableAt,
                            onKindSwipe: changeKind, onKindDrag: dragKind, historyCheckpoint: model.checkpoint, resumePositions: model.resumePositions,
                            onDetailsVisibility: { feed.setTagPolicyDeferred($0) }, onClose: { gridViewer = nil }) {
                await model.nextAndFillUpcoming(session: session, minimumUpcoming: preloadReserve)
            }
        }
        .navigationDestination(item: $creator) { CreatorView(creator: $0.creator, initialKind: $0.kind) }
        .onChange(of: presentation) { _, layout in
            if layout == .grid { gridAnchor = model.focused }
        }
        .onChange(of: gridAnchor) { _, id in
            if presentation == .grid && gridViewer == nil && isVisible, let id { model.focused = id }
        }
        .onChange(of: model.focusRequest) { _, _ in if presentation == .grid { gridAnchor = model.focused } }
        .onChange(of: model.queueRevision) { _, _ in
            if presentation == .grid { gridAnchor = model.focused }
            requestAppearanceFill()
        }
        .onChange(of: presentation) { _, _ in requestAppearanceFill() }
        .onChange(of: mediaPrefetchCount) { _, _ in requestAppearanceFill() }
        .onChange(of: feed.items.map(\.id)) { _, _ in requestAppearanceFill() }
        .onChange(of: gridViewer) { _, value in
            model.setVisible(isVisible && scenePhase == .active && (navigationVisible || value != nil))
        }
        .task(id: historyContext) { model.bindHistory(ownerID: session.tagLibraryOwnerID) }
        .task(id: loadKey) {
            #if DEBUG && targetEnvironment(simulator)
            if qaController != nil && !ResumePromptQA.scenario.hasPrefix("restart-") {
                model.setVisible(laneVisible && scenePhase == .active)
                return
            }
            #endif
            await model.activate(session: session, visible: laneVisible && scenePhase == .active, blockedTags: blocklist.names)
            if presentation == .stream, model.shouldFillOnAppearance {
                await model.fillUpcoming(session: session, minimumUpcoming: preloadReserve)
            }
        }
        .onChange(of: restartRequest) { _, _ in
            handlePendingRestart()
        }
        .onChange(of: topRequest) { _, _ in handlePendingTop() }
        .onChange(of: blocklist.names) { _, names in model.applyBlockedTags(names); requestAppearanceFill() }
        .onChange(of: session.following) { _, ids in Task { await model.followingChanged(ids, session: session) } }
        .onChange(of: isVisible) { _, visible in
            model.setVisible(laneVisible && scenePhase == .active)
            if !visible { cancelContinuationAction() }
            if visible { handlePendingTop(); handlePendingRestart() }
            else { handledTopRequest = topRequest; handledRestartRequest = restartRequest }
        }
        .onAppear {
            navigationVisible = true; model.setVisible(isVisible && scenePhase == .active)
            #if DEBUG && targetEnvironment(simulator)
            if let qaController {
                qaController.setMediaActive = { qaMediaActive = $0 }
                qaController.attach(model: model, session: session, history: history)
            }
            #endif
            handlePendingTop(); handlePendingRestart()
        }
        .onDisappear {
            cancelContinuationAction()
            chrome.resume(after: filterChromeScope)
            navigationVisible = false; model.setVisible(isVisible && gridViewer != nil)
            #if DEBUG && targetEnvironment(simulator)
            qaController?.visibilityChanged(isVisible && gridViewer != nil)
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelContinuationAction() }
            model.setVisible(laneVisible && phase == .active)
        }
    }

    private func requestAppearanceFill() {
        guard presentation == .stream, model.shouldFillOnAppearance else { return }
        Task { await model.fillUpcoming(session: session, minimumUpcoming: preloadReserve) }
    }
    private func handlePendingTop() {
        guard isVisible && navigationVisible, topRequest > handledTopRequest else { return }
        handledTopRequest = topRequest
        model.scrollToStart()
    }

    private func handlePendingRestart() {
        guard isVisible && navigationVisible, restartRequest > handledRestartRequest else { return }
        handledRestartRequest = restartRequest
        model.setVisible(true)
        model.requestRestartFromStart(session: session)
    }

    private func startContinuationAction(_ action: @escaping () async -> Void) {
        guard continuationAction == nil, laneVisible, scenePhase == .active else { return }
        let owner = UUID(); continuationActionID = owner
        continuationAction = Task {
            await action()
            guard continuationActionID == owner else { return }
            continuationAction = nil; continuationActionID = nil
        }
    }
    private func cancelContinuationAction() {
        continuationAction?.cancel(); continuationAction = nil; continuationActionID = nil
    }

    private var deckIsVisible: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if qaController != nil { return isVisible && navigationVisible && qaMediaActive }
        #endif
        return isVisible && navigationVisible
    }

    private func changeKind(_ direction: Int) {
        let kinds = MediaKind.allCases
        guard let index = kinds.firstIndex(of: filter.effectiveKind) else { return }
        model.selectFilter(filter.selecting(kind: kinds[min(max(index + direction, 0), kinds.count - 1)]))
    }
    private func dragKind(_ delta: Double, _ phase: MediaPanPhase) {
        switch phase {
        case .began, .changed:
            kindDrag = min(max(delta, -160), 160)
            let ready = abs(delta) >= 45 && draggedKind != nil
            if ready && !kindDragReady { UISelectionFeedbackGenerator().selectionChanged() }
            withAnimation(.easeOut(duration: 0.12)) { kindDragReady = ready }
        case .ended, .cancelled:
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { kindDrag = 0; kindDragReady = false }
        }
    }
}

