import SwiftUI
import UIKit

private extension View {
    @ViewBuilder func resumePromptQAFrame(_ key: String) -> some View {
        #if DEBUG && targetEnvironment(simulator)
        if CollectionPagingQA.enabled {
            background(GeometryReader { proxy in
                Color.clear.preference(key: CollectionPagingQAFrameKey.self, value: [key: proxy.frame(in: .global)])
            })
        } else if ResumePromptQA.enabled {
            background(GeometryReader { proxy in
                Color.clear.preference(key: ResumePromptQAFrameKey.self, value: [key: proxy.frame(in: .global)])
            })
        } else { self }
        #else
        self
        #endif
    }
}

/// Transient viewing state. Scope leases follow the existing viewer lifecycle;
/// only the foremost visible deck can toggle, and leaving it restores navigation.
@MainActor final class ViewingChromeController: ObservableObject {
    static let shared = ViewingChromeController()
    @Published private(set) var hidden = false
    @Published private(set) var activeScope: UUID?
    @Published private(set) var hasViewer = false
    private var scopes: [UUID] = []
    private var overlays = Set<UUID>()
    var isSuspended: Bool { !overlays.isEmpty }
    #if DEBUG && targetEnvironment(simulator)
    @Published private(set) var qaToggleCount = 0
    #endif
    func begin(_ scope: UUID) {
        guard !scopes.contains(scope) else { return }
        scopes.append(scope); hasViewer = true; activeScope = overlays.isEmpty ? scope : nil; hidden = false
    }
    func end(_ scope: UUID) {
        guard scopes.contains(scope) else { return }
        let wasForemost = activeScope == scope
        scopes.removeAll { $0 == scope }
        hasViewer = !scopes.isEmpty
        if wasForemost { activeScope = scopes.last; hidden = false }
    }
    func suspend(for overlay: UUID) {
        guard overlays.insert(overlay).inserted else { return }
        activeScope = nil; hidden = false
    }
    func resume(after overlay: UUID) {
        guard overlays.remove(overlay) != nil else { return }
        activeScope = overlays.isEmpty ? scopes.last : nil; hidden = false
    }
    func toggle(_ scope: UUID) {
        guard activeScope == scope else { return }
        hidden.toggle()
        #if DEBUG && targetEnvironment(simulator)
        qaToggleCount += 1
        #endif
    }
    func reveal() { hidden = false }
    func isHidden(for scope: UUID) -> Bool { activeScope == scope && hidden }
}

private struct ViewingChromeBottomExclusionKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}
private struct MediaContinuationFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}
private struct ViewingChromeToggleKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}
private struct ViewingBottomBarHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}
/// A shared floating-control baseline. It positions overlays without reducing
/// the media canvas, including full-screen entries which have no visible tabs.
private struct ViewingControlsReferenceInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}
private struct MediaActionHitFramesKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value.append(contentsOf: nextValue()) }
}
extension EnvironmentValues {
    var viewingControlsReferenceInset: CGFloat {
        get { self[ViewingControlsReferenceInsetKey.self] }
        set { self[ViewingControlsReferenceInsetKey.self] = newValue }
    }
    var viewingBottomBarHeight: CGFloat {
        get { self[ViewingBottomBarHeightKey.self] }
        set { self[ViewingBottomBarHeightKey.self] = newValue }
    }
    var viewingChromeBottomExclusion: CGFloat? {
        get { self[ViewingChromeBottomExclusionKey.self] }
        set { self[ViewingChromeBottomExclusionKey.self] = newValue }
    }
    var viewingChromeToggle: (() -> Void)? {
        get { self[ViewingChromeToggleKey.self] }
        set { self[ViewingChromeToggleKey.self] = newValue }
    }
}
extension View {
    /// Keep the subtree and its playback identity in place while hiding chrome.
    func viewingChromeHidden(_ hidden: Bool) -> some View {
        opacity(hidden ? 0 : 1).allowsHitTesting(!hidden).accessibilityHidden(hidden)
    }
    fileprivate func mediaActionHitFrame(in space: Namespace.ID) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: MediaActionHitFramesKey.self, value: [geometry.frame(in: .named(space))])
        })
    }
}

enum MediaDisplayType: Equatable {
    case image
    case video
}

private extension View {
    @ViewBuilder func mediaControlQAFrame(_ key: String) -> some View {
        #if DEBUG && targetEnvironment(simulator)
        if VisualControlsQA.enabled || CollectionPagingQA.enabled || PlaybackLayoutQA.enabled {
            background(GeometryReader { geometry in
                Color.clear.preference(key: CollectionPagingQAFrameKey.self, value: [key: geometry.frame(in: .global)])
                    .preference(key: PlaybackLayoutQAFrameKey.self, value: [key: geometry.frame(in: .global)])
            })
        } else { self }
        #else
        self
        #endif
    }
}

struct MediaActionLabel: View {
    let title: String
    let symbol: String
    var busy = false
    let qaKey: String
    @ScaledMetric(relativeTo: .caption) private var iconSize = 12
    @ScaledMetric(relativeTo: .caption) private var titleWidth = 36
    var body: some View {
        Label {
            Text(title).lineLimit(1).frame(minWidth: titleWidth).mediaControlQAFrame(qaKey + ".text")
        } icon: {
            Image(systemName: symbol).font(.system(size: iconSize, weight: .semibold))
                .frame(width: iconSize, height: iconSize).mediaControlQAFrame(qaKey + ".icon")
        }
        .font(.caption.weight(.semibold)).opacity(busy ? 0 : 1)
        .overlay { if busy { ProgressView().tint(.white).controlSize(.small) } }
    }
}

/// Bare media actions have a transparent 44-point target, never a visible tray.
struct MediaIconActionLabel: View {
    let title: String
    let symbol: String
    let qaKey: String
    var body: some View {
        Image(systemName: symbol).font(.system(size: 23, weight: .medium))
            .foregroundStyle(.white.opacity(0.78))
            .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
            .mediaControlQAFrame(qaKey + ".icon")
            .frame(width: 44, height: 44).contentShape(Rectangle())
            .mediaControlQAFrame(qaKey).accessibilityLabel(title)
    }
}

struct MediaActionButtonStyle: ButtonStyle {
    let prominent: Bool
    var following = false
    let qaKey: String
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 6).frame(minHeight: 44)
            .foregroundStyle(.white.opacity(following ? 0.7 : 0.95))
            .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
            .contentShape(Rectangle()).opacity(configuration.isPressed ? 0.55 : 1)
            .mediaControlQAFrame(qaKey)
    }
}

/// The shared chrome for ordinary full-screen media viewers. Navigation and
/// author routing stay with the presenting screen because those lifecycles differ.
struct FeedContinuationStatusView: View {
    let state: FeedContinuationState
    var empty = false
    var darkCanvas = false
    var performing = false
    var restartRetryAvailableAt: Date? = nil
    let retry: () -> Void
    var restart: (() -> Void)? = nil
    var adjust: (() -> Void)? = nil

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 0.5)) { context in
            VStack(spacing: 8) {
                switch state {
                case .loading, .scanning:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        if empty { Text("正在查找作品…") }
                    }.accessibilityIdentifier("feed.continuation.loading")
                case .ended:
                    Text(empty ? "当前条件下没有更多作品" : "已经看到最后啦")
                        .accessibilityIdentifier("feed.continuation.ended")
                    if empty, let adjust {
                        Button(action: adjust) { Text("调整筛选").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
                    }
                case .failed(let failure):
                    Text(failure.requiresRestart ? "分页加载停滞" : "加载失败")
                        .accessibilityIdentifier("feed.continuation.error")
                    Text(failure.message).lineLimit(3)
                    if failure.requiresRestart {
                        if let restart {
                            Button(action: restart) { Text("重新加载").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
                                .disabled(performing || (restartRetryAvailableAt.map { $0 > context.date } ?? false))
                                .accessibilityIdentifier("feed.continuation.restart")
                        }
                    } else {
                        Button(action: retry) { Text("重试").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
                            .disabled(performing || (failure.retryAvailableAt.map { $0 > context.date } ?? false))
                            .accessibilityIdentifier("feed.continuation.retry")
                    }
                case .ready:
                    if empty { ProgressView("正在查找作品…") }
                }
            }
            .font(.caption).multilineTextAlignment(.center)
            .foregroundStyle(darkCanvas ? Color.white : Color.primary)
            .tint(darkCanvas ? .white : .accentColor)
            .shadow(color: darkCanvas ? .black.opacity(0.75) : .clear, radius: 2, y: 1)
            .frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct FeedMediaViewer: View {
    let items: [MediaItem]
    @Binding var focused: Int?
    let initialID: Int
    var focusRequest = 0
    var queueRevision = 0
    var playbackSuspended = false
    var automaticLoadingAllowed = true
    var continuationState: FeedContinuationState? = nil
    var loadMoreAutomatically: (() async -> Void)? = nil
    var refreshFromStart: (() async -> Void)? = nil
    var restartRetryAvailableAt: Date? = nil
    var onKindSwipe: ((Int) -> Void)? = nil
    var onKindDrag: ((Double, MediaPanPhase) -> Void)? = nil
    var historyCheckpoint: ((MediaItem) -> TimelineCheckpoint?)? = nil
    var resumePositions: [Int: Double] = [:]
    var onDetailsVisibility: ((Bool) -> Void)? = nil
    let onClose: () -> Void
    let loadMore: () async -> Void
    @Environment(\.ordinaryColorScheme) private var ordinaryScheme
    @State private var creator: CreatorRoute?
    @ObservedObject private var chrome = ViewingChromeController.shared

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()
                MediaDeck(items: items, focused: $focused, focusRequest: focusRequest, queueRevision: queueRevision,
                          playbackSuspended: playbackSuspended, automaticLoadingAllowed: automaticLoadingAllowed, initialID: initialID,
                          continuationState: continuationState, loadMoreAutomatically: loadMoreAutomatically,
                          refreshFromStart: refreshFromStart, restartRetryAvailableAt: restartRetryAvailableAt,
                          onKindSwipe: onKindSwipe, onKindDrag: onKindDrag, onAuthor: { creator = $0 }, onDetailsVisibility: onDetailsVisibility,
                          historyCheckpoint: historyCheckpoint, resumePositions: resumePositions,
                          loadMore: loadMore)
                Button(action: onClose) {
                    Image(systemName: "xmark").foregroundStyle(.white)
                        .padding(15).background(.black.opacity(0.4), in: Circle())
                }.padding(15).accessibilityLabel("关闭作品").viewingChromeHidden(chrome.hidden)
            }.tint(.white)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $creator) { CreatorView(creator: $0.creator, initialKind: $0.kind) }
        }.preferredColorScheme(creator == nil ? .dark : ordinaryScheme)
            .environment(\.viewingBottomBarHeight, 0)
    }
}

struct MediaDeck: View {
    let items: [MediaItem]
    @Binding var focused: Int?
    var focusRequest = 0
    var queueRevision = 0
    var playbackSuspended = false
    var automaticLoadingAllowed = true
    var loadsPageOnAppearance = true
    var initialID: Int? = nil
    var isVisible = true
    var showsLoadMore = true
    var continuationState: FeedContinuationState? = nil
    var loadMoreAutomatically: (() async -> Void)? = nil
    var refreshFromStart: (() async -> Void)? = nil
    var restartRetryAvailableAt: Date? = nil
    var bottomBarInset: CGFloat? = nil
    var continuationTopInset: CGFloat = 0
    var gestureTopExclusion: CGFloat = 110
    var gestureExcludedFrames: [CGRect] = []
    var onKindSwipe: ((Int) -> Void)? = nil
    var onKindDrag: ((Double, MediaPanPhase) -> Void)? = nil
    let onAuthor: (CreatorRoute) -> Void
    var onDetailsVisibility: ((Bool) -> Void)? = nil
    var historyCheckpoint: ((MediaItem) -> TimelineCheckpoint?)? = nil
    var resumePositions: [Int: Double] = [:]
    var endAction: (() -> Void)? = nil
    let loadMore: () async -> Void
    @EnvironmentObject private var session: SiteSession
    @ObservedObject private var blocklist = TagBlocklist.shared
    @ObservedObject private var authorBlocks = AuthorBlocklist.shared
    @ObservedObject private var history = BrowsingHistory.shared
    @ObservedObject private var chrome = ViewingChromeController.shared
    @StateObject private var preloader = MediaPreloader()
    @AppStorage("wifiVideoPrefetch") private var wifiVideoPrefetch = true
    @AppStorage("mediaPrefetchCount") private var mediaPrefetchCount = 6
    @AppStorage(MediaPrefetchConcurrency.defaultsKey) private var mediaPrefetchConcurrency = MediaPrefetchConcurrency.defaultValue
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.ordinaryColorScheme) private var ordinaryScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var advance = PlaybackAdvanceState()
    @State private var boundaryDemand: MediaContinuationIntent?
    @State private var detailsItem: MediaItem?
    @State private var detailTagSnapshot: Set<String>?
    @State private var orientationScope = UUID()
    @State private var detailsChromeScope = UUID()
    @State private var pageRecoveryRequest = 0
    @State private var pagedQueueRevision: Int?
    @State private var appeared = false
    @State private var continuationAction: Task<Void, Never>?
    @State private var continuationActionID: UUID?
    @State private var continuationStatusFrame: CGRect = .zero
    @State private var boundaryDragOffset: CGFloat = 0
    @Environment(\.viewingControlsReferenceInset) private var controlsReferenceInset
    private var visibleItems: [MediaItem] { items.filter { !authorBlocks.blocks($0) && TagPolicy.verdict(names: $0.tagNames, blocked: detailTagSnapshot ?? blocklist.names) == .allowed } }
    private var historyContext: HistoryContext? { history.context(ownerID: session.tagLibraryOwnerID) }
    private var viewerVisible: Bool { appeared && isVisible && !session.showLogin }
    private var continuationIntentContext: String { "\(session.feedIdentity):\(queueRevision):\(focusRequest)" }
    private var awaitingNextItem: Bool {
        guard let boundaryDemand, let focused else { return false }
        return viewerVisible && scenePhase == .active && !playbackSuspended && detailsItem == nil &&
            boundaryDemand.context == continuationIntentContext &&
            (boundaryDemand.anchorID == focused || boundaryDemand.targetID == focused)
    }
    private struct PrefetchDemand: Equatable {
        let focus: Int?
        let context: String
        let active: Bool
        let count: Int
        let concurrency: Int
        let wifiOnly: Bool
        let window: [MediaItem]
    }
    private var prefetchDemand: PrefetchDemand {
        let index = focused.flatMap { id in visibleItems.firstIndex(where: { $0.id == id }) }
        let count = [3, 6, 10].contains(mediaPrefetchCount) ? mediaPrefetchCount : 6
        let concurrency = MediaPrefetchConcurrency.validated(mediaPrefetchConcurrency)
        let window = index.map { Array(visibleItems.dropFirst($0).prefix(count + 1)) } ?? []
        return PrefetchDemand(focus: focused, context: "\(session.feedIdentity):\(queueRevision)",
            active: viewerVisible && scenePhase == .active && !playbackSuspended,
            count: count, concurrency: concurrency, wifiOnly: wifiVideoPrefetch, window: window)
    }

    var body: some View {
        GeometryReader { geometry in
            NativeMediaPager(ids: pageIDs, focused: $focused, initialID: initialID,
                             focusRequest: focusRequest &+ pageRecoveryRequest, queueRevision: queueRevision,
                             viewport: geometry.size,
                             accessibilityIdentifier: historyCheckpoint == nil ? "media.viewer.deck" : "timeline.media.deck",
                             isVisible: viewerVisible && scenePhase == .active,
                             onUserPageSettled: { id in
                pagedQueueRevision = queueRevision
                if let demand = boundaryDemand, demand.anchorID != id && demand.targetID != id { boundaryDemand = nil }
            }, onUserContinuationDemand: { id in
                guard showsLoadMore, continuationState != .ended,
                      continuationState?.isLoading != true, continuationState?.requiresRestart != true else { return }
                startContinuationAction(loadMore)
            }, onUserBoundaryDemand: { id in
                if showsLoadMore, !playbackSuspended, id == focused {
                    // The native pager owns the settled tail. A response can
                    // already be in SwiftUI while its native queue waits for this
                    // gesture to finish, so resolve an available next ID too.
                    boundaryDemand = .init(anchorID: id, context: continuationIntentContext)
                    resolveBoundaryDemand()
                }
            }, boundaryWaiting: awaitingNextItem, onUserBoundaryCancel: {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { cancelBoundaryDemand() }
            }, onBoundaryDrag: { offset, phase in
                switch phase {
                case .began, .changed:
                    var transaction = Transaction(); transaction.disablesAnimations = true
                    withTransaction(transaction) { boundaryDragOffset = offset }
                case .ended, .cancelled:
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { boundaryDragOffset = 0 }
                }
            }, onPageDisplayed: { id in
                if let demand = boundaryDemand, demand.context == continuationIntentContext,
                   demand.targetID == id, focused == id, awaitingNextItem { boundaryDemand = nil }
            }) { id, settled in
                let content = page(id: id, settled: settled, size: geometry.size)
                    // Move rendered content inside its stable native host. The
                    // pager's hit-test viewport and internal queue stay in place.
                    .offset(y: awaitingNextItem ? max(0, boundaryDragOffset) - geometry.size.height : boundaryDragOffset)
                    .allowsHitTesting(!awaitingNextItem).accessibilityHidden(awaitingNextItem)
                    .environmentObject(session).environmentObject(session.oauth)
                    .environment(\.ordinaryColorScheme, ordinaryScheme)
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
                    .environment(\.verticalSizeClass, verticalSizeClass)
                    .environment(\.viewingBottomBarHeight, bottomBarInset ?? controlsReferenceInset)
                    .preferredColorScheme(.dark)
                #if DEBUG && targetEnvironment(simulator)
                if ResumePromptQA.enabled { return AnyView(content.defaultAppStorage(ResumePromptQA.defaults)) }
                #endif
                return AnyView(content)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .task(id: "\(focused ?? -1):\(viewerVisible && scenePhase == .active):\(playbackSuspended):\(automaticLoadingAllowed):\(queueRevision):\(pagedQueueRevision.map(String.init) ?? "nil")") {
                guard viewerVisible, scenePhase == .active, !playbackSuspended, automaticLoadingAllowed,
                      let id = focused, let index = visibleItems.firstIndex(where: { $0.id == id }) else { return }
                if loadsPageOnAppearance || pagedQueueRevision == queueRevision,
                   showsLoadMore, continuationState == nil || continuationState == .ready,
                   index >= visibleItems.count - (prefetchDemand.count + 1) { await (loadMoreAutomatically ?? loadMore)() }
            }
            .task(id: prefetchDemand) {
                guard !Task.isCancelled else { return }
                guard viewerVisible, scenePhase == .active, !playbackSuspended,
                      let id = focused, let index = visibleItems.firstIndex(where: { $0.id == id }) else { preloader.stop(); return }
                preloader.update(visibleItems, after: index, count: prefetchDemand.count,
                    context: prefetchDemand.context, wifiOnly: wifiVideoPrefetch,
                    concurrency: prefetchDemand.concurrency)
            }
            .onChange(of: visibleItems) { previous, current in
                resolveBoundaryDemand()
                if current.isEmpty { revealFallbackControls() }
                let target = MediaFocusPolicy.target(current: focused, previousItems: previous, items: current)
                if target != focused { focused = target }
            }
            .onChange(of: focused) { _, id in
                if let demand = boundaryDemand, demand.anchorID != id && demand.targetID != id { boundaryDemand = nil }
                advance.focusChanged(id)
                if let id, id < 0, viewerVisible, chrome.activeScope == orientationScope { chrome.reveal() }
            }
            .onChange(of: queueRevision) { _, _ in
                advance = PlaybackAdvanceState(); boundaryDemand = nil
            }
            .onChange(of: focusRequest) { _, _ in boundaryDemand = nil }
            .onChange(of: playbackSuspended) { _, value in if value { cancelBoundaryDemand() } }
            .onChange(of: continuationState) { previous, value in
                resolveBoundaryDemand()
                if viewerVisible, value?.failure != nil, previous?.failure == nil { chrome.reveal() }
            }
            .onChange(of: awaitingNextItem) { _, waiting in
                if !waiting { boundaryDragOffset = 0 }
            }
        }.clipped().background(.black)
            .overlay {
                if awaitingNextItem {
                    ZStack {
                        Color.black.allowsHitTesting(false)
                        if let state = continuationState, state.failure != nil || state == .ended {
                            FeedContinuationStatusView(state: state, empty: true, darkCanvas: true,
                                performing: continuationAction != nil, restartRetryAvailableAt: restartRetryAvailableAt,
                                retry: { startContinuationAction(loadMore) },
                                restart: refreshFromStart.map { action in { startContinuationAction(action) } })
                                .padding(.horizontal, 28)
                        } else {
                            VStack(spacing: 10) {
                                ProgressView().controlSize(.small).tint(.white.opacity(0.8))
                                    .dynamicTypeSize(.medium).frame(width: 20, height: 20)
                                    .accessibilityIdentifier("media.boundary.waiting")
                                Text("正在加载…").font(.caption).foregroundStyle(.white.opacity(0.7))
                                    .accessibilityIdentifier("media.boundary.message")
                            }.allowsHitTesting(false)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("media.boundary.state")
                    .offset(y: boundaryDragOffset)
                }
            }
            .clipped()
            .overlay {
                if viewerVisible && visibleItems.isEmpty {
                    VStack(spacing: 14) {
                        if let state = continuationState, state.isLoading || state.failure != nil || state == .ended {
                            FeedContinuationStatusView(state: state, empty: true, darkCanvas: true,
                                performing: continuationAction != nil, restartRetryAvailableAt: restartRetryAvailableAt,
                                retry: { startContinuationAction(loadMore) },
                                restart: refreshFromStart.map { action in { startContinuationAction(action) } })
                        } else {
                            Text("当前没有可展示的作品").font(.callout)
                                .accessibilityIdentifier("media.empty.message")
                            if showsLoadMore {
                                Button("继续查找") { startContinuationAction(loadMore) }
                                    .buttonStyle(AppActionButtonStyle(tone: .neutral))
                                    .disabled(continuationAction != nil)
                                    .accessibilityIdentifier("media.empty.continue")
                            }
                        }
                    }
                    .foregroundStyle(.white).padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("media.empty.state")
                    .onAppear {
                        revealFallbackControls()
                        LocalDiagnosticsStore.shared.note(area: .lifecycle, code: .emptyMediaViewport,
                            count: min(items.count, 1_000_000))
                    }
                }
            }
            .overlay(alignment: .top) {
                if showsLoadMore, let state = continuationState, viewerVisible, !visibleItems.isEmpty, !awaitingNextItem,
                   !state.isLoading,
                   (focused == visibleItems.last?.id || state.failure != nil),
                   !chrome.isHidden(for: orientationScope) {
                    FeedContinuationStatusView(state: state, empty: false, darkCanvas: true,
                        performing: continuationAction != nil, restartRetryAvailableAt: restartRetryAvailableAt,
                        retry: { startContinuationAction(loadMore) },
                        restart: refreshFromStart.map { action in { startContinuationAction(action) } })
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: MediaContinuationFrameKey.self,
                                                   value: proxy.frame(in: .named(orientationScope)))
                        })
                        .padding(.horizontal, 60).padding(.top, continuationTopInset + 8)
                }
            }
            .coordinateSpace(name: orientationScope)
            .onPreferenceChange(MediaContinuationFrameKey.self) { continuationStatusFrame = $0 }
            #if DEBUG && targetEnvironment(simulator)
            .modifier(CollectionPagingQAObserver(focused: focused))
            .overlay(alignment: .topTrailing) {
                if (CollectionPagingQA.enabled || PlaybackLayoutQA.enabled) && viewerVisible {
                    let state = "hidden=\(chrome.isHidden(for: orientationScope));toggles=\(chrome.qaToggleCount);scope=\(orientationScope.uuidString)"
                    Text(state).font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                        .accessibilityIdentifier("media.qa.chrome").accessibilityValue(state)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if CollectionPagingQA.enabled && viewerVisible { MediaPreloadQAReadback(preloader: preloader, pagingAllowed: automaticLoadingAllowed) }
            }
            #endif
            .sheet(item: $detailsItem, onDismiss: { detailTagSnapshot = nil; onDetailsVisibility?(false); chrome.resume(after: detailsChromeScope) }) { MediaDetailsView(item: $0) }
            .onAppear { appeared = true; syncViewingChrome(); if viewerVisible && scenePhase == .active { ViewingOrientationController.shared.beginViewer(orientationScope) } }
            .onChange(of: isVisible) { _, value in
                if !value { cancelBoundaryDemand(); cancelContinuationAction(); preloader.stop() }
                syncViewingChrome()
                if value && appeared && !session.showLogin && scenePhase == .active { ViewingOrientationController.shared.beginViewer(orientationScope) }
                else if !value { ViewingOrientationController.shared.endViewer(orientationScope) }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { cancelBoundaryDemand(); cancelContinuationAction(); preloader.stop() }
                syncViewingChrome()
                if phase == .active && viewerVisible { ViewingOrientationController.shared.beginViewer(orientationScope) }
            }
            .onChange(of: session.showLogin) { _, shown in
                if shown { cancelBoundaryDemand(); cancelContinuationAction(); preloader.stop() }
                syncViewingChrome()
            }
            .onChange(of: detailsItem) { _, item in
                if item != nil { cancelBoundaryDemand(); chrome.suspend(for: detailsChromeScope) }
                else { chrome.resume(after: detailsChromeScope) }
            }
            .onDisappear { appeared = false; cancelBoundaryDemand(); cancelContinuationAction(); preloader.stop(); chrome.end(orientationScope); chrome.resume(after: detailsChromeScope); ViewingOrientationController.shared.endViewer(orientationScope) }
    }

    private func resolveBoundaryDemand() {
        guard let demand = boundaryDemand else { return }
        let active = viewerVisible && scenePhase == .active && !playbackSuspended && detailsItem == nil
        let ids = visibleItems.map(\.id)
        guard active, demand.context == continuationIntentContext, let current = focused,
              current == demand.anchorID || current == demand.targetID,
              ids.contains(demand.anchorID) else { boundaryDemand = nil; return }
        if let target = demand.targetID {
            if !ids.contains(target) { boundaryDemand = nil }
            return
        }
        if let target = demand.target(focused: focused, ids: ids, context: continuationIntentContext, active: active) {
            if demand.cause == .failedPlayback,
               advance.target(failedID: demand.anchorID, focused: focused, ids: ids, active: active) == nil {
                boundaryDemand = nil
                return
            }
            var pending = demand
            pending.targetID = target
            boundaryDemand = pending
            focused = target
        }
    }

    private func cancelBoundaryDemand() {
        if let demand = boundaryDemand, let target = demand.targetID, demand.context == continuationIntentContext,
           target == focused, visibleItems.contains(where: { $0.id == demand.anchorID }) {
            focused = demand.anchorID
        }
        boundaryDemand = nil
        boundaryDragOffset = 0
    }

    private func startContinuationAction(_ action: @escaping () async -> Void) {
        guard continuationAction == nil, viewerVisible, scenePhase == .active, !playbackSuspended else { return }
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

    private func revealFallbackControls() {
        guard viewerVisible, scenePhase == .active, chrome.activeScope == orientationScope else { return }
        chrome.reveal()
    }
    private func syncViewingChrome() {
        if viewerVisible && scenePhase == .active {
            chrome.begin(orientationScope)
            if visibleItems.isEmpty { revealFallbackControls() }
        } else { chrome.end(orientationScope) }
    }

    private var pageIDs: [Int] {
        guard !visibleItems.isEmpty else { return [] }
        return visibleItems.map(\.id) + (endAction == nil ? [] : [-2])
    }

    @ViewBuilder private func page(id: Int, settled: Bool, size: CGSize) -> some View {
        if let item = visibleItems.first(where: { $0.id == id }) {
            MediaPageView(item: item, active: settled && (focused == item.id || (awaitingNextItem && boundaryDemand?.anchorID == item.id)) && viewerVisible && !playbackSuspended && scenePhase == .active,
                          chromeScope: orientationScope, onToggleChrome: { chrome.toggle(orientationScope) },
                          gestureTopExclusion: gestureTopExclusion,
                          gestureExcludedFrames: gestureExcludedFrames + (continuationStatusFrame.isEmpty ? [] : [continuationStatusFrame]),
                          onKindSwipe: onKindSwipe, onKindDrag: onKindDrag, onAuthor: onAuthor, pausedForDetails: detailsItem != nil || awaitingNextItem, onDetails: { value in
                guard detailsItem == nil else { return }
                detailTagSnapshot = blocklist.names; onDetailsVisibility?(true); detailsItem = value
            }, onUnavailable: { id in
                guard viewerVisible, !playbackSuspended, scenePhase == .active, detailsItem == nil,
                      advance.canAdvance(failedID: id, focused: focused, active: true),
                      boundaryDemand?.anchorID != id else { return }
                let ids = visibleItems.map(\.id)
                let hasNext = ids.firstIndex(of: id).map { ids.indices.contains($0 + 1) } ?? false
                guard hasNext || (showsLoadMore && automaticLoadingAllowed) else { return }
                boundaryDemand = .init(anchorID: id, context: continuationIntentContext, cause: .failedPlayback)
                resolveBoundaryDemand()
                if boundaryDemand != nil, continuationState != .ended, continuationState?.isLoading != true,
                   continuationState?.requiresRestart != true {
                    startContinuationAction(loadMoreAutomatically ?? loadMore)
                }
            }, historyContext: historyContext, resumePosition: resumePositions[item.id], retainDuringInterruption: (focused == item.id || boundaryDemand?.anchorID == item.id) && isVisible, onQualifiedExposure: { item, context in
                history.record(item, context: context, checkpoint: historyCheckpoint?(item))
            }).id("\(item.id):queue:\(queueRevision)")
                .frame(width: size.width, height: size.height).clipped()
                .resumePromptQAFrame("page-\(item.id)")
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("media-page-\(item.id)")
        } else if id == -2, let endAction {
            VStack(spacing: 18) {
                Image(systemName: "checkmark.circle").font(.largeTitle)
                Text("已看完这段浏览记录").font(.headline)
                Button("加载当前最新内容", action: endAction).buttonStyle(.borderedProminent)
            }.foregroundStyle(.white).frame(width: size.width, height: size.height)
        } else {
            VStack(spacing: 12) {
                Text("作品列表已更新").font(.callout)
                if let next = visibleItems.first {
                    Button("返回当前作品") { focused = next.id; pageRecoveryRequest &+= 1 }
                        .buttonStyle(AppActionButtonStyle(tone: .neutral))
                }
            }.foregroundStyle(.white).frame(width: size.width, height: size.height)
                .accessibilityIdentifier("media.page.updated")
                .onAppear { revealFallbackControls() }
        }
    }

}

struct MediaPageView: View {
    let item: MediaItem
    let active: Bool
    var chromeScope: UUID? = nil
    var onToggleChrome: (() -> Void)? = nil
    var gestureTopExclusion: CGFloat = 110
    var gestureExcludedFrames: [CGRect] = []
    var onKindSwipe: ((Int) -> Void)? = nil
    var onKindDrag: ((Double, MediaPanPhase) -> Void)? = nil
    let onAuthor: (CreatorRoute) -> Void
    var pausedForDetails = false
    var onDetails: ((MediaItem) -> Void)? = nil
    var onUnavailable: ((Int) -> Void)? = nil
    var historyContext: HistoryContext? = nil
    var resumePosition: Double? = nil
    var retainDuringInterruption = false
    var onQualifiedExposure: ((MediaItem, HistoryContext) -> Void)? = nil
    @EnvironmentObject private var session: SiteSession
    @ObservedObject private var chrome = ViewingChromeController.shared
    @State private var creator: Creator?
    @State private var resolving = false
    @State private var error: String?
    @State private var revealed = false
    @State private var mediaReady = false
    @State private var qualifiedContext: HistoryContext?
    @State private var actualDisplayType: MediaDisplayType?
    @State private var actionHitFrames: [CGRect] = []
    @Namespace private var actionSpace
    @Environment(\.viewingBottomBarHeight) private var bottomBarHeight
    private var chromeHidden: Bool { chromeScope.map { chrome.isHidden(for: $0) } ?? false }
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var chromeAvailable: Bool { chromeScope.map { chrome.activeScope == $0 } ?? false }
    private var displayType: MediaDisplayType { actualDisplayType ?? (item.isVideo ? .video : .image) }
    private var displaysVideo: Bool { displayType == .video }
    private var effectiveItem: MediaItem { item.resolvingMediaType(isVideo: displaysVideo) }
    private var shouldBlur: Bool { (session.account?.blurNsfw ?? true) && ((item.browsingLevel ?? 1) & 28 != 0) }
    private var canRecord: Bool { active && mediaReady && !pausedForDetails && (!shouldBlur || revealed) }
    private struct ExposureKey: Equatable { let record: Bool; let context: HistoryContext?; let id: Int }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            Group {
                if let url = item.mediaURL {
                    if displaysVideo {
                        VideoSurface(url: url, poster: item.posterURL, active: active && (!shouldBlur || revealed), diagnosticWorkID: item.id, diagnosticOffline: item.offlineMediaURL != nil, gesturesActive: active, gestureTopExclusion: chromeHidden ? 0 : gestureTopExclusion, gestureExcludedFrames: chromeHidden ? [] : gestureExcludedFrames + actionHitFrames,
                                     chromeHidden: chromeHidden, onChromeHold: chromeAvailable ? toggleChrome : nil, pausedForOverlay: pausedForDetails, retainDuringInterruption: retainDuringInterruption, mediaBlurred: shouldBlur && !revealed,
                                     onKindSwipe: onKindSwipe, onKindDrag: onKindDrag, onDoubleTap: openAuthor,
                                     refreshURL: {
                            if item.offlineMediaURL != nil { return item.mediaURL }
                            let refreshed = try await session.mediaItem(id: item.id)
                            guard let refreshed, TagPolicy.verdict(names: refreshed.tagNames, blocked: TagBlocklist.shared.names) == .allowed else { return nil }
                            return refreshed.mediaURL
                        }, onConfirmedUnavailable: { onUnavailable?(item.id) }, resumePosition: resumePosition,
                                     onProgress: { position, duration, flush in
                            let history = BrowsingHistory.shared
                            guard let context = qualifiedContext ?? historyContext,
                                  HistoryProgressPolicy.allows(qualifiedVisit: qualifiedContext == context,
                                      existingVideo: history.records.contains { $0.id == item.id && $0.kind == .video },
                                      contextIsCurrent: history.accepts(context), recordingEnabled: history.recordingEnabled) else { return }
                            history.progress(id: item.id, position: position, duration: duration, flush: flush, context: context)
                        }, onDisplayReady: { mediaReady = $0 }, onImageContent: { actualDisplayType = .image },
                                     footer: { muted in mediaActions(muted: muted) })
                    }
                    else {
                        BitmapMediaSurface(url: url, active: active && (!shouldBlur || revealed), gestureTopExclusion: chromeHidden ? 0 : gestureTopExclusion, gestureExcludedFrames: chromeHidden ? [] : gestureExcludedFrames + actionHitFrames, pausedForOverlay: pausedForDetails,
                                           onReady: { mediaReady = $0 }, onVideoContent: confirmVideoContent,
                                           onKindSwipe: onKindSwipe, onKindDrag: onKindDrag, onDoubleTap: openAuthor)
                            .blur(radius: shouldBlur && !revealed ? 24 : 0)
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.circle").font(.title2)
                        Text("这条作品暂时无法打开").font(.callout)
                        Text("媒体地址不可用，可查看详情或切换作品").font(.caption).foregroundStyle(.secondary)
                    }.foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("media.source.unavailable")
                        .onAppear { revealMissingSourceControls() }
                }
            }
            if shouldBlur && !revealed {
                Button { revealed = true } label: { Label("显示这条作品", systemImage: "eye").padding(14).background(.ultraThinMaterial, in: Capsule()) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).viewingChromeHidden(chromeHidden)
            }
            if !displaysVideo || item.mediaURL == nil { mediaActions().padding(.horizontal, 20).padding(.bottom, bottomBarHeight + 8) }
        }.clipped()
        .coordinateSpace(name: actionSpace)
        .onPreferenceChange(MediaActionHitFramesKey.self) { actionHitFrames = $0 }
        .environment(\.viewingChromeToggle, chromeAvailable && active && !pausedForDetails ? toggleChrome : nil)
        .environment(\.viewingChromeBottomExclusion, chromeHidden ? 0 : (displaysVideo ? nil : bottomBarHeight + 8))
        .task(id: active) {
            if active && creator == nil && item.offlineMediaURL == nil { creator = try? await resolveCreator() }
        }
        .task(id: ExposureKey(record: canRecord, context: historyContext, id: item.id)) {
            guard canRecord, let context = historyContext else { return }
            do { try await Task.sleep(for: .seconds(2)); try Task.checkCancellation() } catch { return }
            guard BrowsingHistory.shared.accepts(context) else { return }
            qualifiedContext = context; onQualifiedExposure?(effectiveItem, context)
        }
        .onChange(of: active) { _, value in
            if value { qualifiedContext = nil; revealMissingSourceControls() }
        }
        .onChange(of: chromeAvailable) { _, value in if value { revealMissingSourceControls() } }
    }

    private func revealMissingSourceControls() {
        guard active, item.mediaURL == nil, chromeAvailable, !pausedForDetails else { return }
        chrome.reveal()
    }

    private func mediaActions(muted: Binding<Bool>? = nil) -> some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 4) {
                    authorLink.layoutPriority(0)
                    if let creator, item.offlineMediaURL == nil {
                        FollowButton(creator: creator, mediaItemID: item.id).fixedSize(horizontal: true, vertical: false).layoutPriority(1)
                    } else if resolving { ProgressView().controlSize(.small) }
                    Spacer(minLength: 0)
                }.mediaControlQAFrame("control.\(item.id).social")
                if let error { Text(error).font(.caption2).lineLimit(2).foregroundStyle(.white).shadow(color: .black, radius: 2) }
            }.frame(maxWidth: .infinity, alignment: .leading).mediaActionHitFrame(in: actionSpace)
            VStack(spacing: verticalSizeClass == .compact ? 0 : 8) {
                if item.offlineMediaURL != nil {
                    MediaIconActionLabel(title: "离线", symbol: "internaldrive.fill", qaKey: "control.\(item.id).offline")
                } else { FavoriteButton(item: item, active: active) }
                Button { onDetails?(effectiveItem) } label: {
                    MediaIconActionLabel(title: "作品详情", symbol: "info.circle", qaKey: "control.\(item.id).details")
                }.buttonStyle(.plain).accessibilityLabel("作品详情")
                if let muted {
                    Button { muted.wrappedValue.toggle() } label: {
                        MediaIconActionLabel(title: muted.wrappedValue ? "取消静音" : "静音",
                                             symbol: muted.wrappedValue ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                             qaKey: "control.\(item.id).mute")
                    }.buttonStyle(.plain).accessibilityLabel(muted.wrappedValue ? "取消静音" : "静音")
                }
                Button { ViewingOrientationController.shared.toggleViewerOrientation() } label: {
                    MediaIconActionLabel(title: "手动切换横竖屏", symbol: "rectangle.portrait.rotate", qaKey: "control.\(item.id).rotate")
                }.buttonStyle(.plain).accessibilityLabel("手动切换横竖屏")
            }.fixedSize(horizontal: true, vertical: false).mediaActionHitFrame(in: actionSpace)
        }.tint(.white).viewingChromeHidden(chromeHidden)
            #if DEBUG && targetEnvironment(simulator)
            .playbackQAFrame("actions")
            .resumePromptQAFrame("actions-\(item.id)")
            #endif
    }

    private var authorLink: some View {
        Button(action: openAuthor) {
            HStack(spacing: 4) {
                Text("@" + (item.username ?? "作者")).font(.headline).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.right").font(.caption)
            }.frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
                .foregroundStyle(.white).shadow(color: .black.opacity(0.65), radius: 2, y: 1)
        }.buttonStyle(.plain).accessibilityIdentifier("media.author.\(item.id)")
            .mediaControlQAFrame("control.\(item.id).author")
    }
    private func toggleChrome() {
        guard active, !pausedForDetails, chromeAvailable else { return }
        onToggleChrome?()
    }

    private func confirmVideoContent() {
        // A positive image probe is more specific than the bitmap decoder's
        // generic "video content" response; do not oscillate between surfaces.
        if actualDisplayType == nil { actualDisplayType = .video }
    }

    private func resolveCreator() async throws -> Creator {
        if let creator { return creator }
        guard let username = item.username else { throw ClientError.missingCreator }
        resolving = true; defer { resolving = false }
        let value = try await session.creator(username: username); creator = value; return value
    }
    private func openAuthor() {
        guard active else { return }
        Task {
            do { let value = try await resolveCreator(); onAuthor(CreatorRoute(creator: value, item: effectiveItem)) }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// Shared compact failure content. Grid retries are siblings of the open button,
/// so a retry cannot accidentally navigate into the failed work.
struct MediaLoadFailureContent: View {
    let message: String
    var symbol = "photo"
    var retryLabel = "重试图片"
    var retryIdentifier = ""
    var retry: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.secondary)
            Text(message).font(.caption).multilineTextAlignment(.center).lineLimit(3)
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let retry {
                Button(action: retry) { Label(retryLabel, systemImage: "arrow.clockwise").font(.caption) }
                    .buttonStyle(AppActionButtonStyle()).fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier(retryIdentifier)
            }
        }.padding(12).frame(maxWidth: 260)
    }
}

struct CachedImage: View {
    let url: URL
    var fit = false
    var onReady: ((Bool) -> Void)? = nil
    var allowsRetry = true
    var retryToken = 0
    var onFailure: ((Bool) -> Void)? = nil
    var showsFailure = true
    var onFailureMessage: ((String?) -> Void)? = nil
    @State private var image: UIImage?
    @State private var failure: String?
    @State private var retry = 0
    private struct RequestKey: Equatable { let url: URL; let retry: Int; let externalRetry: Int }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.06)
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: fit ? .fit : .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else if let failure {
                    if showsFailure {
                        MediaLoadFailureContent(message: failure, retry: allowsRetry ? { retry += 1 } : nil)
                    }
                } else { ProgressView() }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .task(id: RequestKey(url: url, retry: retry, externalRetry: retryToken)) {
            guard !Task.isCancelled else { return }
            onReady?(false); onFailure?(false); onFailureMessage?(nil); image = nil; failure = nil
            do {
                let value = try await MediaCache.shared.loadImage(url)
                guard !Task.isCancelled else { return }
                image = value; onReady?(true)
            } catch {
                guard !Task.isCancelled else { return }
                if let known = error as? ImageLoadError {
                    failure = known.localizedDescription
                    let code: DiagnosticCode
                    switch known { case .decode: code = .decode; case .queueFull: code = .queueFull; default: code = .storage }
                    LocalDiagnosticsStore.shared.note(area: .thumbnail, code: code)
                } else if let known = error as? MediaDownloadError {
                    failure = known.localizedDescription
                    if case .http(let status) = known { LocalDiagnosticsStore.shared.note(area: .thumbnail, code: .http, httpStatus: status) }
                    else { LocalDiagnosticsStore.shared.note(area: .thumbnail, code: .invalidResponse) }
                } else { failure = "图片暂时无法加载"; LocalDiagnosticsStore.shared.note(area: .thumbnail, code: .network) }
                onFailure?(true)
                onFailureMessage?(failure)
            }
        }
        .onDisappear { image = nil; onReady?(false) }
    }
}
