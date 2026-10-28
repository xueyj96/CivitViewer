import SwiftUI

// Full-canvas works stay primary. A quiet bookmark opens a native folder picker;
// saved work uses the existing grid, paging, video gestures and disk cache.
struct FavoriteButton: View {
    let item: MediaItem
    let active: Bool
    @EnvironmentObject private var session: SiteSession
    @State private var showPicker = false
    @State private var chromeOverlay = UUID()
    @ObservedObject private var chrome = ViewingChromeController.shared
    private var saved: Bool { !(session.savedMemberships[item.id] ?? []).isEmpty }
    var body: some View {
        Button { showPicker = true } label: {
            MediaIconActionLabel(title: saved ? "已收藏" : "收藏", symbol: saved ? "bookmark.fill" : "bookmark", qaKey: "control.\(item.id).favorite")
        }
        .buttonStyle(.plain).accessibilityLabel(saved ? "已收藏" : "收藏")
        .accessibilityIdentifier("favorite-\(item.id)")
        .sheet(isPresented: $showPicker, onDismiss: { chrome.resume(after: chromeOverlay) }) { FavoriteEditor(item: item) }
        .onChange(of: showPicker) { _, shown in
            if shown { chrome.suspend(for: chromeOverlay) }
            else { chrome.resume(after: chromeOverlay) }
        }
        .onDisappear { chrome.resume(after: chromeOverlay) }
        .task(id: "\(active):\(session.hasCollectionAccess)") {
            if active && session.hasCollectionAccess { _ = try? await session.refreshSavedMembership(item.id) }
        }
    }
}

struct CollectionAccessView: View {
    @EnvironmentObject private var session: SiteSession
    @State private var showAuthorization = false
    var body: some View {
        ContentUnavailableView {
            Label(session.account == nil ? "登录后查看收藏" : "启用账号收藏", systemImage: "bookmark")
        } description: {
            Text("读取 Civitai 收藏夹，保存图片和视频，并在这里继续浏览。需要收藏读取与管理权限。")
        } actions: {
            Button { showAuthorization = true } label: {
                Text(session.account == nil ? "登录并启用收藏" : "补充收藏授权").frame(minHeight: 44)
            }.buttonStyle(AppActionButtonStyle(tone: .accent))
        }
        .ordinaryAppearance()
        .sheet(isPresented: $showAuthorization, onDismiss: { session.oauth.cancel() }) {
            CollectionAuthorizationView()
        }
        .onChange(of: session.hasCollectionAccess) { _, allowed in if allowed { showAuthorization = false } }
    }
}

private struct CollectionAuthorizationView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        LoginView(forCollections: true, onClose: { dismiss() }).ordinaryAppearance()
    }
}

struct CollectionsView: View {
    @EnvironmentObject private var session: SiteSession
    @State private var loading = false
    @State private var error: String?
    @State private var showCreate = false
    var body: some View {
        Group {
            if !session.hasCollectionAccess { CollectionAccessView() }
            else {
                List {
                    Section {
                        ForEach(session.collections) { collection in
                            NavigationLink { CollectionWorksView(collection: collection) } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: collection.mode == "Bookmark" ? "bookmark.fill" : "folder").font(.title3).foregroundStyle(.blue).frame(width: 26)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(collection.name).font(.headline)
                                        Text("\(collection.privacyTitle) · 图片／视频").font(.caption).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 7)
                            }
                        }
                    } footer: { Text("与当前 Civitai 账号同步。只列出你拥有的图片／视频收藏夹。") }
                    if session.collections.isEmpty && !loading && error == nil {
                        ContentUnavailableView("还没有图片／视频收藏夹", systemImage: "bookmark", description: Text("可以新建私密收藏夹，或在作品页点收藏。"))
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.secondary); Button("重试") { Task { await refresh() } } }
                    if loading { ProgressView() }
                    Button { showCreate = true } label: { Label("新建私密收藏夹", systemImage: "folder.badge.plus") }
                }.refreshable { await refresh() }
            }
        }
        .navigationTitle("我的收藏").ordinaryAppearance().appNavigationBack().environment(\.defaultMinListRowHeight, 52)
        .toolbar { if session.hasCollectionAccess { Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }.disabled(loading).accessibilityLabel("刷新收藏夹") } }
        .task(id: "\(session.account?.id ?? -1):\(session.hasCollectionAccess)") { if session.hasCollectionAccess { await refresh() } }
        .sheet(isPresented: $showCreate) { CreateCollectionView() }
    }
    private func refresh() async {
        guard !loading else { return }; loading = true; error = nil
        defer { loading = false }
        do { try await session.refreshCollections() } catch { self.error = error.localizedDescription }
    }
}

private struct FavoriteEditor: View {
    let item: MediaItem
    @EnvironmentObject private var session: SiteSession
    @Environment(\.dismiss) private var dismiss
    @State private var original = Set<Int>()
    @State private var selected = Set<Int>()
    @State private var loading = false
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?
    @State private var showCreate = false
    var body: some View {
        NavigationStack {
            Group {
                if !session.hasCollectionAccess { CollectionAccessView() }
                else {
                    List {
                        Section {
                            ForEach(session.collections) { collection in
                                Button {
                                    if selected.contains(collection.id) { selected.remove(collection.id) }
                                    else { selected.insert(collection.id) }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: selected.contains(collection.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(selected.contains(collection.id) ? .blue : .secondary)
                                        VStack(alignment: .leading, spacing: 5) { Text(collection.name).foregroundStyle(.primary); Text(collection.privacyTitle).font(.caption).foregroundStyle(.secondary) }
                                    }.padding(.vertical, 5)
                                }.disabled(!loaded || saving)
                            }
                        } footer: { Text("新收藏默认勾选上次保存的收藏夹。取消勾选会从对应收藏夹移除；公开收藏夹中的作品可被他人看到。") }
                        Button { showCreate = true } label: { Label("新建私密收藏夹", systemImage: "folder.badge.plus") }.disabled(saving || loading)
                        if loading || saving { ProgressView(saving ? "正在保存并核对…" : "正在读取收藏状态…") }
                        if let error {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                            Button("重新读取收藏状态") { Task { await load() } }.disabled(saving || loading)
                        }
                    }
                }
            }
            .navigationTitle(item.isVideo ? "收藏视频" : "收藏图片").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                AppToolbarItem(placement: .confirmationAction) { Button("保存") { Task { await save() } }.disabled(!loaded || loading || saving || selected == original) }
            }
            .task(id: "\(session.account?.id ?? -1):\(session.hasCollectionAccess)") { if session.hasCollectionAccess { await load() } }
            .sheet(isPresented: $showCreate) { CreateCollectionView { collection in selected.insert(collection.id) } }
            .interactiveDismissDisabled(saving)
        }.ordinaryAppearance().environment(\.defaultMinListRowHeight, 52)
    }
    private func load() async {
        guard !loading else { return }; loading = true; loaded = false; error = nil
        defer { loading = false }
        do {
            try await session.refreshCollections()
            let ids = try await session.refreshSavedMembership(item.id, force: true)
            original = ids; selected = ids.isEmpty ? session.defaultCollectionIDs : ids; loaded = true
        } catch { self.error = error.localizedDescription }
    }
    private func save() async {
        guard loaded && !saving else { return }; saving = true; error = nil
        defer { saving = false }
        do { try await session.saveCollectionSelection(imageID: item.id, original: original, selected: selected); session.rememberCollectionSelection(selected); dismiss() }
        catch { self.error = error.localizedDescription; loaded = false }
    }
}

private struct CreateCollectionView: View {
    var onCreated: ((SavedCollection) -> Void)? = nil
    @EnvironmentObject private var session: SiteSession
    @Environment(\.dismiss) private var dismiss
    @State private var name = "收藏作品"
    @State private var saving = false
    @State private var error: String?
    @State private var needsRefresh = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("收藏夹名称", text: $name).disabled(saving)
                    LabeledContent("可见范围", value: "私密")
                } footer: { Text("保存在 Civitai 账号中，支持图片与视频。名称最多 30 个字符；已有同名私密收藏夹时直接使用。") }
                if saving { ProgressView("正在创建并核对…") }
                if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
                if needsRefresh { Button("刷新收藏夹后重试") { Task {
                    do { try await session.refreshCollections(); needsRefresh = false; error = nil }
                    catch { self.error = error.localizedDescription }
                } } }
            }
            .navigationTitle("新建收藏夹").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                AppToolbarItem(placement: .confirmationAction) { Button("创建") { Task {
                    saving = true; error = nil
                    defer { saving = false }
                    do { let collection = try await session.createPrivateCollection(name: name); onCreated?(collection); dismiss() }
                    catch { self.error = error.localizedDescription; needsRefresh = true }
                } }.disabled(saving || needsRefresh || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.utf16.count > 30) }
            }.interactiveDismissDisabled(saving)
        }.ordinaryAppearance().environment(\.defaultMinListRowHeight, 52)
    }
}

private struct CollectionWorksView: View {
    let collection: SavedCollection
    @EnvironmentObject private var session: SiteSession
    @ObservedObject private var blocklist = TagBlocklist.shared
    @StateObject private var feed = FeedStore(diagnostics: .shared, observations: .shared, authorBlocks: .shared)
    @State private var kind: MediaKind = .all
    @State private var onlyPG = false
    @State private var durationRange: VideoDurationRange?
    @State private var showFilter = false
    @State private var viewerItem: MediaItem?
    @State private var focused: Int?
    @State private var needsRefresh = false
    private var collectionFilter: FeedFilter { FeedFilter(kind: kind, onlyPG: onlyPG, videoDurationRange: durationRange) }
    private var requestKey: FeedStoreRequestKey { .init(identity: session.feedIdentity, filter: collectionFilter, source: .collection(collection.id)) }
    private var mediaKindSelection: Binding<MediaKind> {
        Binding(get: { collectionFilter.effectiveKind }, set: { value in
            let selected = collectionFilter.selecting(kind: value)
            kind = selected.kind; durationRange = selected.videoDurationRange
        })
    }
    var body: some View {
        Group {
            if !session.hasCollectionAccess { CollectionAccessView() }
            else {
                VStack(spacing: 0) {
                    HStack {
                        Picker("收藏作品类型", selection: mediaKindSelection) { ForEach(MediaKind.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                        Menu {
                            Button("筛选条件") { showFilter = true }.accessibilityIdentifier("collection-show-filter")
                            Toggle("仅看 PG", isOn: $onlyPG)
                            Button("刷新作品") { Task { await refreshFeed() } }
                        } label: { Image(systemName: "line.3.horizontal.decrease").frame(width: 44, height: 44) }.accessibilityLabel("收藏筛选与刷新").accessibilityIdentifier("collection-filter-menu")
                    }.padding(16)
                    MediaGrid(feed: feed, adjustFilter: { showFilter = true }, isVisible: viewerItem == nil, refreshFromStart: refreshFeed) { item in focused = item.id; viewerItem = item } loadMore: { await feed.next(session: session) }
                        .refreshable { await refreshFeed() }
                }
            }
        }
        .navigationTitle(collection.name).navigationBarTitleDisplayMode(.inline).ordinaryAppearance().appNavigationBack()
        .task(id: requestKey) {
            guard session.hasCollectionAccess else { feed.clear(); return }
            let retainedKey = feed.requestKey == requestKey
            let commit = await feed.activate(session: session, filter: requestKey.filter, source: .collection(collection.id), blockedTags: blocklist.names)
            if !retainedKey && feed.accepts(commit, identity: session.feedIdentity) { focused = nil }
        }
        .onChange(of: session.hasCollectionAccess) { _, allowed in
            if allowed { Task { await reload() } } else { feed.clear() }
        }
        .onChange(of: blocklist.names) { _, tags in feed.applyBlockedTags(tags) }
        .onChange(of: session.collectionRevision) { _, _ in
            if viewerItem == nil { Task { await reload() } } else { needsRefresh = true }
        }
        .sheet(isPresented: $showFilter) {
            NavigationStack {
                Form {
                    Section("内容范围") {
                        Toggle("仅看 PG", isOn: $onlyPG)
                        Text("关闭“仅看 PG”时，内容范围遵循 Civitai 账号和站点规则。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    VideoDurationFilterSection(range: $durationRange)
                    Button("重置筛选") { kind = .all; onlyPG = false; durationRange = nil }
                    Text("选择立即生效；关闭面板保留当前选择。").font(.caption).foregroundStyle(.secondary)
                }
                .navigationTitle("收藏筛选").navigationBarTitleDisplayMode(.inline)
                    .environment(\.defaultMinListRowHeight, 52)
                .toolbar {
                    AppToolbarItem(placement: .confirmationAction) { Button("完成") { showFilter = false } }
                }
            }.ordinaryAppearance()
        }
        .fullScreenCover(item: $viewerItem, onDismiss: {
            if needsRefresh { needsRefresh = false; Task { await reload() } }
        }) { opening in
            FeedMediaViewer(items: feed.items, focused: $focused, initialID: opening.id,
                            continuationState: feed.continuationState, loadMoreAutomatically: { await feed.nextAutomatically(session: session) },
                            refreshFromStart: refreshFeed, restartRetryAvailableAt: feed.restartRetryAvailableAt,
                            onDetailsVisibility: { feed.setTagPolicyDeferred($0) }, onClose: { viewerItem = nil }) {
                await feed.next(session: session)
            }
        }
    }
    private func reload() async {
        guard session.hasCollectionAccess else { feed.clear(); return }
        _ = await feed.activate(session: session, filter: collectionFilter, source: .collection(collection.id), blockedTags: blocklist.names, force: true)
    }
    private func refreshFeed() async {
        if await feed.restartCurrentFeed(session: session)?.status == .committed { focused = feed.items.first?.id }
    }
}
