import SwiftUI

struct SearchView: View {
    @StateObject private var directory = TagDirectoryStore(diagnostics: .shared)
    @State private var text = ""
    @State private var author: Creator?
    @State private var tags: [SearchTag] = []
    @State private var showTags = false
    @State private var showAuthors = false
    @State private var showMatchingHelp = false
    @State private var destination: MediaSearchTarget?
    init(initialCriteria: MediaSearchCriteria = .init()) {
        _text = State(initialValue: initialCriteria.text)
        _author = State(initialValue: initialCriteria.author)
        _tags = State(initialValue: initialCriteria.tags)
    }
    private var criteria: MediaSearchCriteria { .init(text: text, author: author, tags: tags) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("搜索条件").font(.headline)
                    Spacer()
                    if !text.isEmpty || author != nil || !tags.isEmpty {
                        Button("清空") { text = ""; author = nil; tags = [] }
                            .buttonStyle(AppActionButtonStyle())
                            .accessibilityLabel("清空全部条件")
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("标题开头", systemImage: "text.alignleft").font(.subheadline.weight(.medium))
                        Spacer()
                        Text("可选").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        TextField("输入作品帖标题前缀", text: $text)
                            .frame(minHeight: 44).accessibilityIdentifier("search-title-input")
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .submitLabel(.search).onSubmit(search)
                        if !text.isEmpty {
                            Button { text = "" } label: { Image(systemName: "xmark").font(.caption) }
                                .buttonStyle(AppActionButtonStyle()).accessibilityLabel("清空文本")
                        }
                    }
                    Divider()
                    HStack(spacing: 8) {
                        Button { showAuthors = true } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                                Text(author.map { "@" + $0.username } ?? "选择作者").lineLimit(2)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }.font(.subheadline).frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("search-author-picker")
                        if author != nil {
                            Button { author = nil } label: { Image(systemName: "xmark").font(.caption) }
                                .buttonStyle(AppActionButtonStyle()).accessibilityLabel("不限作者")
                        }
                    }
                    Divider()
                    HStack {
                        Label("标签", systemImage: "tag").font(.subheadline.weight(.medium))
                        Text("\(tags.count) / 8").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        Button { showTags = true } label: { Label(tags.isEmpty ? "选择" : "调整", systemImage: "plus") }
                            .buttonStyle(AppActionButtonStyle(tone: .accent))
                            .accessibilityLabel(tags.isEmpty ? "浏览站内标签并选择" : "添加或调整标签")
                            .accessibilityIdentifier("search-tag-picker")
                    }
                    if tags.isEmpty {
                        Text("可选多个标签，作品须全部包含。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        TagPillLayout(spacing: 7) {
                            ForEach(tags) { tag in
                                Button { tags.removeAll { $0.id == tag.id } } label: {
                                    HStack(spacing: 6) { Text(tag.name).lineLimit(2); Image(systemName: "xmark").font(.caption2) }
                                }.buttonStyle(AppActionButtonStyle(tone: .accent))
                                    .accessibilityLabel("移除搜索标签 " + tag.name)
                            }
                        }
                    }
                }.padding(16).background(AppTheme.secondarySurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                if !text.isEmpty && !MediaSearchText.valid(text, mode: .title) {
                    Text(MediaSearchText.validationMessage).font(.caption).foregroundStyle(.secondary)
                }
                Button(action: search) {
                    Label("搜索作品", systemImage: "magnifyingglass").frame(maxWidth: .infinity)
                }.buttonStyle(AppActionButtonStyle(tone: .accent))
                    .disabled(!criteria.valid).accessibilityIdentifier("search-submit")
                DisclosureGroup("匹配说明", isExpanded: $showMatchingHelp) {
                    Text("标题按开头匹配，忽略大小写，不搜索 prompt 或描述全文。文本、作者与所有标签须同时满足；可只填其中一种。结果遵循账号内容范围及本机屏蔽。")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(16)
        }.scrollDismissesKeyboard(.interactively)
            .navigationTitle("组合搜索").navigationBarTitleDisplayMode(.inline).ordinaryAppearance().appNavigationBack()
            .sheet(isPresented: $showTags) { TagDirectoryView(selected: $tags, store: directory).ordinaryAppearance() }
            .sheet(isPresented: $showAuthors) { AuthorSearchPicker(selected: $author).ordinaryAppearance() }
            .navigationDestination(item: $destination) { SearchWorksView(target: $0) }
    }
    private func search() { if criteria.valid { destination = .combined(criteria) } }
}

struct SearchWorksView: View {
    let target: MediaSearchTarget
    @EnvironmentObject private var session: SiteSession
    @ObservedObject private var blocklist = TagBlocklist.shared
    @StateObject private var feed = FeedStore(diagnostics: .shared, authorBlocks: .shared)
    @State private var filter = FeedFilter(kind: .all, sort: "Newest", period: "AllTime")
    @State private var focused: Int?
    @State private var viewer: MediaItem?
    @State private var showFilter = false
    private var requestKey: FeedStoreRequestKey { .init(identity: session.feedIdentity, filter: filter, source: .search(target)) }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("搜索媒体", selection: Binding(get: { filter.effectiveKind }, set: { filter = filter.selecting(kind: $0) })) { ForEach(MediaKind.allCases) { Text($0.chineseTitle).tag($0) } }.pickerStyle(.segmented)
                    Button { showFilter = true } label: { Image(systemName: "line.3.horizontal.decrease").frame(width: 44, height: 44) }.buttonStyle(AppActionButtonStyle()).accessibilityLabel("搜索结果筛选").accessibilityIdentifier("search-filter-button")
                }
                Text(target.explanation).font(.caption).foregroundStyle(.secondary)
                if target.selectedTags.contains(where: { blocklist.names.contains(TagPolicy.normalize($0.name)) }) {
                    Text("所选标签在本机屏蔽列表中，匹配作品仍会隐藏；可以返回详情撤销屏蔽，或在设置中调整。").font(.caption).foregroundStyle(.secondary)
                }
                Text(filter.summary).font(.caption2).foregroundStyle(.secondary)
                if let progress = feed.searchProgress { Text("已检查 \(progress.pages) 页候选 · 当前显示 \(feed.items.count) 条").font(.caption2).foregroundStyle(.secondary) }
                if feed.loading && feed.items.isEmpty { HStack(spacing: 8) { ProgressView(); Text("正在查找同时满足条件的作品…").font(.caption) } }
                if case .author(let author) = target { NavigationLink("查看作者主页与简介") { CreatorView(creator: author, initialKind: filter.effectiveKind) } }
            }.padding(16)
            MediaGrid(feed: feed, emptyDescription: target.explanation + "当前筛选：" + filter.summary,
                      resetFilter: { filter = .defaults(for: .creator, kind: filter.kind) }, adjustFilter: { showFilter = true },
                      isVisible: viewer == nil, refreshFromStart: refreshFeed) { item in focused = item.id; viewer = item } loadMore: { await feed.next(session: session) }
        }.navigationTitle(target.title).navigationBarTitleDisplayMode(.inline).ordinaryAppearance().appNavigationBack()
            .sheet(isPresented: $showFilter) { FilterView(filter: $filter, context: .creator).ordinaryAppearance() }
            .task(id: requestKey) {
                let retainedKey = feed.requestKey == requestKey
                let commit = await feed.activate(session: session, filter: filter, source: .search(target), blockedTags: blocklist.names)
                if !retainedKey && feed.accepts(commit, identity: session.feedIdentity) { focused = nil }
            }
            .onChange(of: blocklist.names) { _, tags in feed.applyBlockedTags(tags) }
            .fullScreenCover(item: $viewer) { opening in
                FeedMediaViewer(items: feed.items, focused: $focused, initialID: opening.id,
                                continuationState: feed.continuationState, loadMoreAutomatically: { await feed.nextAutomatically(session: session) },
                                refreshFromStart: refreshFeed, restartRetryAvailableAt: feed.restartRetryAvailableAt,
                                onDetailsVisibility: { feed.setTagPolicyDeferred($0) }, onClose: { viewer = nil }) {
                    await feed.next(session: session)
                }
            }
    }
    private func refreshFeed() async {
        if await feed.restartCurrentFeed(session: session)?.status == .committed { focused = feed.items.first?.id }
    }
}
