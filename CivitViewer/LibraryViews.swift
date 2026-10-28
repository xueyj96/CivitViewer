import SwiftUI

struct LeaderboardView: View {
    @EnvironmentObject private var session: SiteSession
    @State private var board: Board = .seasonal
    @State private var recent: RecentPublication = .any
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("作者榜类型", selection: $board) { ForEach(Board.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                HStack {
                    Text("作品更新").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Picker("作品更新时间", selection: $recent) {
                            ForEach(RecentPublication.allCases) { Text($0.title).tag($0) }
                        }
                    } label: { AppFilterLabel(title: recent.title, symbol: "calendar") }
                        .buttonStyle(AppActionButtonStyle())
                        .accessibilityLabel("作品更新：" + recent.title)
                        .accessibilityIdentifier("leaderboard.recent-filter")
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, AppTheme.spacing).padding(.top, 12).padding(.bottom, 4)
            ZStack {
                ForEach(Board.allCases) { value in
                    LeaderboardList(board: value, visible: board == value, recent: recent)
                        .opacity(board == value ? 1 : 0)
                        .allowsHitTesting(board == value).accessibilityHidden(board != value)
                }
            }
        }.navigationTitle("作者榜").navigationBarTitleDisplayMode(.inline).ordinaryAppearance()
    }
}

// Both boards retain their mounted list and original rank positions.
private struct LeaderboardList: View {
    let board: Board
    let visible: Bool
    let recent: RecentPublication
    @EnvironmentObject private var session: SiteSession
    @State private var entries: [LeaderboardEntry] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?
    @StateObject private var activity = CreatorActivityStore()
    private struct ActivityKey: Equatable { let visible: Bool; let active: Bool; let identity: String; let ids: [Int] }
    private var activityKey: ActivityKey { .init(visible: visible, active: recent != .any, identity: session.feedIdentity, ids: entries.map(\.id)) }
    private var matching: [LeaderboardEntry] {
        entries.filter { entry in
            if recent == .any { return true }
            if case .published(let date) = activity.result(for: entry.id) { return recent.includes(date) }
            return false
        }
    }
    private var unknown: [LeaderboardEntry] { entries.filter { activity.result(for: $0.id) == nil || activity.result(for: $0.id) == .unverified } }
    var body: some View {
        Group {
            if entries.isEmpty {
                if loading { ProgressView().frame(maxHeight: .infinity) }
                else if let error { FailureView(message: error) { Task { await load() } } }
                else { ContentUnavailableView { Label("当前榜单暂无结果", systemImage: "person.3") } actions: { Button("刷新榜单") { Task { await load() } } } }
            } else {
                List {
                    if recent != .any {
                        Section {
                            Text("已核实 \(entries.count - unknown.count) / \(entries.count) 位，符合条件 \(matching.count) 位").font(.subheadline)
                            if activity.busy { ProgressView("正在核实作品发布时间…") }
                            else if !unknown.isEmpty {
                                Button("继续核实下一批作者") { Task { await activity.checkNext(entries.map(\.user), source: session) } }
                                Button("重试待核实作者") { Task { await activity.checkNext(unknown.map(\.user), source: session, retryUnknown: true) } }
                            }
                        } footer: { Text("依据当前账号可见的已发布图片／视频作品帖。原榜单名次保留；未核实、失败或扫描未完成的作者单列待核实，不能视为没有更新。结果缓存 10 分钟。") }
                    }
                    Section(recent == .any ? "榜单作者" : "符合更新范围") {
                        ForEach(matching) { entry in row(entry) }
                        if matching.isEmpty { Text("当前已核实作者中没有符合条件的结果").foregroundStyle(.secondary) }
                    }
                    if recent != .any && !unknown.isEmpty {
                        Section("待核实 · \(unknown.count) 位") { ForEach(unknown) { entry in row(entry) } }
                    }
                }.listStyle(.plain).refreshable { await load() }
                    .overlay(alignment: .bottom) {
                        if error != nil { Button("刷新失败，点此重试") { Task { await load() } }.padding(12).background(.regularMaterial, in: Capsule()).padding() }
                    }
            }
        }.task(id: visible) { if visible && !loaded && !loading { await load() } }
            .task(id: activityKey) {
                guard visible, recent != .any else { return }
                await activity.checkNext(entries.map(\.user), source: session)
            }
    }
    private func row(_ entry: LeaderboardEntry) -> some View {
        NavigationLink { CreatorView(creator: entry.user) } label: {
            HStack(spacing: 14) {
                Text(String(format: "%02d", entry.position)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 25)
                AvatarView(name: entry.user.username)
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.user.username).font(.headline)
                    if recent == .any { Text("图片／视频").font(.caption).foregroundStyle(.secondary) }
                    else if case .published(let date) = activity.result(for: entry.id) {
                        Text("作品发布 " + date.formatted(.dateTime.locale(Locale(identifier: "zh_Hans_CN")).year().month().day())).font(.caption).foregroundStyle(.secondary)
                    } else { Text("作品更新时间待核实").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if session.following.contains(entry.user.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
            }.padding(.vertical, 7)
        }
    }
    private func load() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let value = try await session.leaderboard(board)
            guard !Task.isCancelled else { return }
            entries = value.filter { !$0.user.username.isEmpty }; loaded = true
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

struct AvatarView: View {
    let name: String
    var body: some View { Text(String(name.prefix(1)).uppercased()).font(.headline).foregroundStyle(.white).frame(width: 43, height: 43).background(Color(red: 0.18, green: 0.36, blue: 0.43), in: Circle()) }
}

struct CreatorView: View {
    let creator: Creator
    @EnvironmentObject private var session: SiteSession
    @ObservedObject private var blocklist = TagBlocklist.shared
    @ObservedObject private var authorBlocklist = AuthorBlocklist.shared
    @StateObject private var feed = FeedStore(diagnostics: .shared, observations: .shared, authorBlocks: AuthorBlocklist.shared)
    @State private var filter: FeedFilter
    @State private var showFilter = false
    @State private var focused: Int?
    @State private var viewerItem: MediaItem?
    @State private var authorBlockError: String?
    @State private var headerScrollRequest = 0
    private var requestKey: FeedStoreRequestKey { .init(identity: session.feedIdentity, filter: filter, source: .creator(creator)) }
    private var creatorBlocked: Bool { authorBlocklist.contains(id: creator.id) }
    private var creatorIdentityHeader: some View {
        HStack(spacing: 14) {
            AvatarView(name: creator.username)
            VStack(alignment: .leading, spacing: 5) { Text(creator.username).font(.title3.bold()); Text("@" + creator.username).font(.caption).foregroundStyle(.secondary) }
            Spacer(); FollowButton(creator: creator)
        }.padding(AppTheme.spacing)
    }
    private var creatorFeedHeader: some View {
        VStack(spacing: 0) {
            creatorIdentityHeader
            if let authorBlockError { Text(authorBlockError).font(.caption).foregroundStyle(.red).padding(.horizontal, 18) }
            CreatorBiographyView(creator: creator, onCollapse: { headerScrollRequest += 1 })
                .padding(.horizontal, 18).padding(.bottom, 12)
            HStack {
                Picker("作者媒体类型", selection: Binding(get: { filter.effectiveKind }, set: { filter = filter.selecting(kind: $0) })) { Text(MediaKind.image.title).tag(MediaKind.image); Text(MediaKind.video.title).tag(MediaKind.video) }.pickerStyle(.segmented).accessibilityIdentifier("creator.media-kind")
                Button { showFilter = true } label: { Image(systemName: "line.3.horizontal.decrease") }.buttonStyle(AppActionButtonStyle()).accessibilityLabel("作者作品筛选")
            }.padding(.horizontal, 16).padding(.bottom, 14)
            HStack {
                Menu {
                    Picker("时间范围", selection: $filter.period) { ForEach(FeedPeriod.allCases) { Text($0.title).tag($0.rawValue) } }
                } label: { AppFilterLabel(title: filter.periodTitle, symbol: "calendar") }.buttonStyle(AppActionButtonStyle()).accessibilityLabel("时间范围：" + filter.periodTitle)
                Spacer()
                Menu {
                    Picker("排序方式", selection: $filter.sort) { ForEach(FeedSort.allCases) { Text($0.title).tag($0.rawValue) } }
                } label: { AppFilterLabel(title: filter.sortTitle, symbol: "arrow.up.arrow.down") }.buttonStyle(AppActionButtonStyle()).accessibilityLabel("排序方式：" + filter.sortTitle)
            }.font(.subheadline).padding(.horizontal, 20).padding(.bottom, 12)
        }
    }
    private var profileURL: URL? {
        let username = creator.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/;?#%"))
        guard !username.isEmpty, let component = username.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: SiteSession.origin + "/user/" + component)
    }
    init(creator: Creator, initialKind: MediaKind = .image) {
        self.creator = creator
        _filter = State(initialValue: .defaults(for: .creator, kind: initialKind == .video ? .video : .image))
    }
    var body: some View {
        VStack(spacing: 0) {
            if creatorBlocked {
                creatorIdentityHeader
                ContentUnavailableView {
                    Label("该作者已在本机屏蔽", systemImage: "person.crop.circle.badge.xmark")
                } description: {
                    Text("此作者的作品仅在本客户端隐藏；站点关注关系和其他本地数据保持不变。")
                } actions: {
                    Button("取消本机屏蔽") { authorBlocklist.remove(id: creator.id); authorBlockError = nil }
                    if let authorBlockError { Text(authorBlockError).font(.caption).foregroundStyle(.red) }
                }
            } else {
                MediaGrid(feed: feed, emptyDescription: filter.summary + "。可切换媒体类型，或调整时间与内容范围。", resetFilter: { filter = .defaults(for: .creator, kind: filter.kind) }, adjustFilter: { showFilter = true }, isVisible: viewerItem == nil, refreshFromStart: refreshFeed, header: AnyView(creatorFeedHeader), headerScrollRequest: headerScrollRequest, open: { item in focused = item.id; viewerItem = item }) { await feed.next(session: session) }
            }
        }
        .navigationTitle("作者作品").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            AppToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let profileURL {
                        Link(destination: profileURL) { Label("在 Civitai 打开", systemImage: "safari") }
                            .accessibilityIdentifier("creator.open-site")
                        ShareLink(item: profileURL) { Label("分享作者", systemImage: "square.and.arrow.up") }
                            .accessibilityIdentifier("creator.share")
                        Divider()
                    }
                    if creatorBlocked {
                        Button {
                            authorBlocklist.remove(id: creator.id); authorBlockError = nil
                        } label: { Label("取消本机屏蔽", systemImage: "person.crop.circle.badge.checkmark") }
                    } else {
                        Button(role: .destructive) {
                            if !authorBlocklist.add(creator) { authorBlockError = authorBlocklist.error ?? "无法加入本机屏蔽名单。" }
                            else { authorBlockError = nil }
                        } label: { Label("在本机屏蔽作者", systemImage: "person.crop.circle.badge.xmark") }
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("作者更多操作")
                .accessibilityIdentifier("creator.actions")
                .buttonStyle(AppActionButtonStyle())
            }
        }
        .sheet(isPresented: $showFilter) { FilterView(filter: $filter, allowAll: false, context: .creator) }
        .fullScreenCover(item: $viewerItem) { opening in
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()
                MediaDeck(items: feed.items, focused: $focused, initialID: opening.id,
                          continuationState: feed.continuationState, loadMoreAutomatically: { await feed.nextAutomatically(session: session) },
                          refreshFromStart: refreshFeed, restartRetryAvailableAt: feed.restartRetryAvailableAt,
                          onAuthor: { _ in viewerItem = nil }, onDetailsVisibility: { feed.setTagPolicyDeferred($0) }) { await feed.next(session: session) }
                CreatorViewerCloseButton { viewerItem = nil }
            }.preferredColorScheme(.dark)
        }
        .task(id: requestKey) {
            guard !creatorBlocked else { feed.invalidatePendingRequests(); return }
            let retainedKey = feed.requestKey == requestKey
            let commit = await feed.activate(session: session, filter: filter, source: .creator(creator), blockedTags: blocklist.names)
            if !retainedKey && feed.accepts(commit, identity: session.feedIdentity) { focused = nil }
        }
        .onChange(of: blocklist.names) { _, tags in feed.applyBlockedTags(tags) }
        .onChange(of: authorBlocklist.entries) { _, _ in
            if creatorBlocked { viewerItem = nil; feed.invalidatePendingRequests() }
            else { Task { _ = await feed.activate(session: session, filter: filter, source: .creator(creator), blockedTags: blocklist.names) } }
        }
        .ordinaryAppearance()
        .appNavigationBack()
    }
    private func refreshFeed() async {
        if await feed.restartCurrentFeed(session: session)?.status == .committed { focused = feed.items.first?.id }
    }
}

private struct CreatorViewerCloseButton: View {
    let close: () -> Void
    @ObservedObject private var chrome = ViewingChromeController.shared
    var body: some View {
        Button(action: close) { Image(systemName: "xmark").foregroundStyle(.white).padding(15).background(.black.opacity(0.4), in: Circle()) }
            .padding(15).accessibilityLabel("关闭作品").viewingChromeHidden(chrome.hidden)
    }
}

extension FeedStore {
    /// Explicit recovery keeps the currently committed source/filter/account.
    @discardableResult
    func restartCurrentFeed(session: any FeedPageReading) async -> FeedRestartResult? {
        guard let key = requestKey, key.identity == session.feedIdentity else { return nil }
        return await restartFromStart(session: session, filter: key.filter, source: key.source, blockedTags: TagBlocklist.shared.names)
    }
}

struct MediaGrid: View {
    @ObservedObject var feed: FeedStore
    var continuationState: FeedContinuationState? = nil
    @EnvironmentObject private var session: SiteSession
    var emptyDescription: String? = nil
    var resetFilter: (() -> Void)? = nil
    var adjustFilter: (() -> Void)? = nil
    var anchor: Binding<Int?>? = nil
    var scrollRequest = 0
    var loadsOnAppearance = true
    var isVisible = true
    var automaticLoadingAllowed = true
    var loadMoreAutomatically: (() async -> Void)? = nil
    var refreshFromStart: (() async -> Void)? = nil
    var header: AnyView? = nil
    var headerScrollRequest = 0
    let open: (MediaItem) -> Void
    let loadMore: () async -> Void
    @State private var userScrolled = false
    @State private var visibleCells = Set<Int>()
    @State private var continuationAction: Task<Void, Never>?
    @State private var continuationActionID: UUID?
    @Environment(\.scenePhase) private var scenePhase
    private var nearEnd: Bool { !Set(feed.items.suffix(4).map(\.id)).isDisjoint(with: visibleCells) }
    private var continuationStatus: FeedContinuationState { continuationState ?? feed.continuationState }
    private struct AutomaticLoadKey: Equatable {
        let request: FeedStoreRequestKey?
        let tail: Int?
        let active: Bool
        let permitted: Bool
        let demanded: Bool
    }
    private var automaticLoadKey: AutomaticLoadKey {
        .init(request: feed.requestKey, tail: feed.items.last?.id, active: isVisible && scenePhase == .active,
              permitted: automaticLoadingAllowed, demanded: (loadsOnAppearance || userScrolled) && (feed.items.isEmpty || nearEnd))
    }
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            if let header { header.id(-1001) }
            if feed.unverifiedDuration > 0 || feed.hiddenByDuration > 0 {
                Text("时长范围隐藏 \(feed.hiddenByDuration) 项；\(feed.unverifiedDuration) 项时长未知，暂不展示。")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 6)
            }
            if feed.durationMetadataFailedPages > 0 {
                Text("视频时长暂时无法取得，当前作品和位置已保留；请稍后重试。")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
            }
            if feed.duplicatesDiscarded > 0 { Text("已去除 \(feed.duplicatesDiscarded) 项重复结果").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 6) }
            if feed.hiddenByTags > 0 || feed.unverifiedTags > 0 {
                Text("标签屏蔽已隐藏 \(feed.hiddenByTags) 项；\(feed.unverifiedTags) 项标签待核实，暂不展示。").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
            }
            if feed.hiddenByAuthors > 0 {
                Text("本机作者屏蔽隐藏 \(feed.hiddenByAuthors) 项；取消屏蔽后可重新显示。").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 6)
            }
            LazyVGrid(columns: [.init(.flexible(), spacing: 8), .init(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(feed.items) { item in
                    MediaGridCell(item: item, blurred: (session.account?.blurNsfw ?? true) && ((item.browsingLevel ?? 1) & 28 != 0)) { open(item) }
                        .onAppear {
                            visibleCells.insert(item.id)
                        }
                        .onDisappear { visibleCells.remove(item.id) }
                }
            }.scrollTargetLayout().padding(.horizontal, 10)
            FeedContinuationStatusView(state: continuationStatus, empty: feed.items.isEmpty,
                                       performing: continuationAction != nil, restartRetryAvailableAt: feed.restartRetryAvailableAt,
                                       retry: { startExplicitAction(loadMore) },
                                       restart: { startExplicitAction(refreshFromStart ?? { _ = await feed.restartCurrentFeed(session: session) }) },
                                       adjust: adjustFilter).padding(.vertical, 16)
            if feed.items.isEmpty, continuationStatus == .ended {
                if let emptyDescription { Text(emptyDescription).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20) }
                if let resetFilter { Button("重置筛选", action: resetFilter).frame(minHeight: 44) }
            }
        }
        .modifier(MediaGridPosition(anchor: anchor))
        .onAppear { if let id = anchor?.wrappedValue { proxy.scrollTo(id, anchor: .top) } }
        .onChange(of: scrollRequest) { _, _ in userScrolled = false; if let id = anchor?.wrappedValue { proxy.scrollTo(id, anchor: .top) } }
        .onChange(of: headerScrollRequest) { _, _ in withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(-1001, anchor: .top) } }
        .task(id: automaticLoadKey) {
            let key = automaticLoadKey
            guard key.active, key.permitted, key.demanded, feed.canAutomaticallyContinue else { return }
            if let loadMoreAutomatically { await loadMoreAutomatically() }
            else { await feed.nextAutomatically(session: session) }
        }
        .onChange(of: isVisible) { _, value in if !value { userScrolled = false; cancelContinuationAction() } }
        .onChange(of: scenePhase) { _, value in if value != .active { cancelContinuationAction() } }
        .onChange(of: feed.requestKey) { _, _ in cancelContinuationAction() }
        .onDisappear { cancelContinuationAction(); visibleCells = [] }
        .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in
            if !userScrolled && !loadsOnAppearance && isVisible {
                userScrolled = true
            }
        }.onEnded { value in
            guard isVisible, scenePhase == .active, nearEnd,
                  value.translation.height < -36, abs(value.translation.height) > abs(value.translation.width) * 1.2,
                  continuationStatus != .ended, !continuationStatus.isLoading, !continuationStatus.requiresRestart else { return }
            // An actual forward scroll is explicit demand. This also releases a
            // programmatic-return gate when a short queue has no new cell to appear.
            startExplicitAction(loadMore)
        })
        #if DEBUG && targetEnvironment(simulator)
        .overlay(alignment: .topLeading) {
            if CollectionPagingQA.enabled {
                Text("count=\(feed.items.count);loading=\(feed.loading);error=\(feed.error ?? "none")")
                    .font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                    .accessibilityIdentifier("collection.qa.grid")
            }
        }
        #endif
        }
        .ordinaryAppearance()
    }
    private func startExplicitAction(_ action: @escaping () async -> Void) {
        guard continuationAction == nil, isVisible, scenePhase == .active else { return }
        let id = UUID()
        continuationActionID = id
        continuationAction = Task {
            defer { if continuationActionID == id { continuationAction = nil; continuationActionID = nil } }
            await action()
        }
    }
    private func cancelContinuationAction() {
        continuationAction?.cancel(); continuationAction = nil; continuationActionID = nil
    }
}

private struct MediaGridPosition: ViewModifier {
    var anchor: Binding<Int?>?
    @ViewBuilder func body(content: Content) -> some View {
        if let anchor { content.scrollPosition(id: anchor, anchor: .top) } else { content }
    }
}

private struct MediaGridCell: View {
    let item: MediaItem
    let blurred: Bool
    let open: () -> Void
    @State private var failure: String?
    @State private var retry = 0
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: open) {
                Group {
                    if item.isVideo, let source = item.mediaURL {
                        CachedPoster(source: source, declared: item.posterURL, retryToken: retry,
                                     onFailure: { failure = $0 ? "封面暂时无法加载" : nil }, showsFailure: false).blur(radius: blurred ? 20 : 0)
                    } else if let url = item.mediaURL {
                        CachedImage(url: url, allowsRetry: false, retryToken: retry, showsFailure: false,
                                    onFailureMessage: { failure = $0 }).blur(radius: blurred ? 20 : 0)
                    } else {
                        ZStack {
                            Color.secondary.opacity(0.1)
                            Label(item.isVideo ? "暂无封面" : "暂无图片", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.frame(height: 230).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(item.isVideo ? "视频" : "图片") \(item.id)")
                .accessibilityIdentifier("media.grid.cell.\(item.id)")
            if item.isVideo {
                Image(systemName: "play.fill").font(.caption).foregroundStyle(.white).padding(8).background(.black.opacity(0.4), in: Circle()).padding(8).allowsHitTesting(false)
            }
            if let failure {
                MediaLoadFailureContent(message: failure, symbol: item.isVideo ? "play.rectangle" : "photo",
                                        retryLabel: item.isVideo ? "重试封面" : "重试图片",
                                        retryIdentifier: "media.grid.retry.\(item.id)", retry: { retry += 1 })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(height: 230).clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Exercises production grid failures with missing local fixtures, no network.
struct GridRetryQAView: View {
    @State private var opened = 0
    private var items: [MediaItem] {
        [false, true].enumerated().map { index, video in
            var item = MediaItem(id: 55_001 + index, url: "", width: 192, height: 256,
                                 type: video ? "video" : "image", username: "LocalFixture", browsingLevel: 1, thumbnail: nil)
            let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-grid55-\(index)")
            item.offlineMediaURL = missing
            if video { item.offlinePosterURL = missing }
            return item
        }
    }
    var body: some View {
        VStack(spacing: 18) {
            Text("本地加载失败布局").font(.headline)
            HStack(spacing: 10) {
                ForEach(items) { item in
                    MediaGridCell(item: item, blurred: false, open: { opened += 1 })
                        .frame(maxWidth: .infinity)
                        .background(AppTheme.secondarySurface, in: RoundedRectangle(cornerRadius: 9))
                }
            }
            Text("opened=\(opened)").accessibilityIdentifier("grid.retry.qa.opens")
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
            .preferredColorScheme(.dark)
            .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("--qa-grid-retry-large55") ? .accessibility2 : .large)
    }
}
#endif

struct FollowingView: View {
    @EnvironmentObject private var session: SiteSession
    @StateObject private var store = FollowingListStore()
    @AppStorage("following.sort") private var sortRaw = FollowingSort.followed.rawValue
    @AppStorage("following.reverseTime") private var reverseTime = false
    @AppStorage("following.reverseName") private var reverseName = false
    private var sort: FollowingSort { FollowingSort(rawValue: sortRaw) ?? .followed }
    private var reverse: Bool { sort == .followed ? reverseTime : reverseName }
    private var key: FollowingListKey { .init(identity: session.followingIdentity, memberIDs: session.following, revision: session.followingRevision) }
    private var current: Bool { store.requestKey == key }
    private var orderIdentity: String { "\(session.followingIdentity):\(sort.rawValue):\(reverse)" }
    var body: some View {
        Group {
            if session.account == nil {
                ContentUnavailableView { Label("登录后查看关注", systemImage: "star") } description: { Text("与 Civitai 账号同步关注关系。") } actions: { Button("登录 Civitai") { session.openLogin() }.buttonStyle(AppActionButtonStyle(tone: .accent)) }
            } else {
                List {
                    Section {
                        Picker("关注作者排序", selection: $sortRaw) {
                            ForEach(FollowingSort.allCases) { value in Text(value.title).tag(value.rawValue) }
                        }.pickerStyle(.segmented)
                        Button {
                            if sort == .followed { reverseTime.toggle() } else { reverseName.toggle() }
                        } label: {
                            HStack {
                                Label(sort == .followed ? "关注时间" : "名称顺序", systemImage: "arrow.up.arrow.down")
                                Spacer()
                                Text(sort == .followed ? (reverse ? "最早关注在前" : "最近关注在前") : (reverse ? "Z–A" : "A–Z")).foregroundStyle(.secondary)
                            }
                        }
                    } footer: {
                        Text(sort == .followed ? "按站点记录的真实关注时间排列。重新关注会按新的关注时间排序。" : "按作者昵称排序，忽略大小写，并将名称中的数字按数值排列。")
                    }
                    if current, store.complete {
                        Section("已关注 \(store.creators.count) 位") {
                            ForEach(store.ordered(sort, reverse: reverse)) { creator in
                            NavigationLink { CreatorView(creator: creator) } label: { HStack(spacing: 12) { AvatarView(name: creator.username); Text(creator.username) }.padding(.vertical, 5) }
                            }
                            if store.creators.isEmpty { Text("你还没有关注作者").foregroundStyle(.secondary) }
                        }
                    } else {
                        Section {
                            if !current || store.loading { ProgressView("正在读取关注作者…") }
                            if current, store.totalItems > 0 { Text("已读取 \(store.creators.count) / \(store.totalItems) 位").font(.subheadline).foregroundStyle(.secondary) }
                            if current, let error = store.error {
                                Text(error).font(.caption).foregroundStyle(.secondary)
                                Button("重新加载关注列表") { Task { await load(force: true) } }
                            } else if current, store.canContinue, !store.loading {
                                Button("继续读取关注作者") { Task { await store.nextBatch(source: session) } }
                            }
                        } footer: {
                            Text("完整读取后统一排序。作者较多时会分批加载，避免只对部分作者排序。")
                        }
                    }
                }.listStyle(.insetGrouped).id(orderIdentity).refreshable { await load(force: true) }
            }
        }.navigationTitle("我的关注").task(id: key) { await load(force: false) }.ordinaryAppearance().appNavigationBack()
    }
    private func load(force: Bool) async {
        guard !Task.isCancelled else { return }
        guard session.account != nil else { store.clear(); return }
        let requestedKey = key
        if !force, store.requestKey == requestedKey, store.complete { return }
        await store.reload(key: requestedKey, source: session)
    }
}
