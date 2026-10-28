import SwiftUI

struct TagDirectoryView: View {
    @Binding var selected: [SearchTag]
    @ObservedObject var store: TagDirectoryStore
    @EnvironmentObject private var session: SiteSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var blocklist = TagBlocklist.shared
    @ObservedObject private var availability = TagMediaAvailability.shared
    @AppStorage("tagDirectory.showSparse") private var showSparse = false
    @State private var mode: TagDirectoryMode
    @State private var query: String
    @State private var selectionError: String?
    @State private var actionTask: Task<Void, Never>?
    @State private var showDirectoryScope = false
    init(selected: Binding<[SearchTag]>, store: TagDirectoryStore) {
        _selected = selected; self.store = store
        _mode = State(initialValue: store.key?.mode ?? .common); _query = State(initialValue: store.key?.keyword ?? "")
    }
    private var keyword: String { TagPolicy.normalize(query) }
    private var activeMode: TagDirectoryMode { keyword.isEmpty ? mode : .catalog }
    private var key: TagDirectoryStore.Key { .init(mode: activeMode, keyword: keyword, identity: session.tagLookupIdentity) }
    private var valid: Bool { keyword.isEmpty || MediaSearchText.valid(keyword, mode: .tag) }
    private struct AvailabilityKey: Hashable { let identity: String; let ids: [Int] }
    private var availabilityKey: AvailabilityKey {
        .init(identity: session.feedIdentity, ids: store.key == key ? store.tags.map(\.id) : [])
    }
    private var displayedTags: [SearchTag] {
        store.tags.filter { tag in showSparse || selected.contains(where: { $0.id == tag.id }) || !availability.isSparse(tagID: tag.id, identity: session.feedIdentity) }
    }
    private var sparseCount: Int {
        store.tags.filter { availability.isSparse(tagID: $0.id, identity: session.feedIdentity) }.count
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索标签名称", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("tag-search-input")
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(AppActionButtonStyle()).accessibilityLabel("清空标签名称")
                        }
                    }.frame(minHeight: 44).padding(.horizontal, 12)
                        .background(AppTheme.secondarySurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    if keyword.isEmpty {
                        Picker("浏览标签", selection: $mode) {
                            ForEach(TagDirectoryMode.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented)
                    }
                    if activeMode == .catalog {
                        Menu {
                            Button("浏览标签目录") { mode = .catalog; query = "" }
                            Section("字母") { ForEach(Array("abcdefghijklmnopqrstuvwxyz"), id: \.self) { letter in Button(String(letter).uppercased()) { query = String(letter) } } }
                            Section("数字") { ForEach(0...9, id: \.self) { digit in Button(String(digit)) { query = String(digit) } } }
                        } label: { AppFilterLabel(title: "首字母", symbol: "textformat.abc") }
                            .buttonStyle(AppActionButtonStyle())
                    }
                    if !selected.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(selected) { tag in
                                    Button { toggle(tag) } label: {
                                        HStack(spacing: 6) { Text(tag.name).lineLimit(1); Image(systemName: "xmark").font(.caption2) }
                                    }.buttonStyle(AppActionButtonStyle(tone: .accent))
                                        .accessibilityLabel("移除搜索标签 " + tag.name)
                                }
                            }
                        }
                    }
                    HStack(spacing: 10) {
                        Text("标签范围").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(showSparse ? "全部标签" : "收起少量作品") { showSparse.toggle() }
                            .font(.caption).buttonStyle(AppActionButtonStyle())
                            .accessibilityLabel(showSparse ? "收起作品较少的标签" : "显示全部标签，包括少量作品标签")
                            .accessibilityIdentifier("tag-directory.sparse-toggle")
                    }
                }.padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 12)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(keyword.isEmpty ? activeMode.title : "匹配标签").font(.headline)
                            Spacer()
                            Text("已选 \(selected.count) / 8").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if let selectionError { Text(selectionError).font(.caption).foregroundStyle(.secondary) }
                    if store.key == key {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], alignment: .leading, spacing: 8) {
                            ForEach(displayedTags) { tag in
                                let chosen = selected.contains(where: { $0.id == tag.id })
                            Button { toggle(tag) } label: {
                                HStack(spacing: 7) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(tag.name).font(.subheadline).lineLimit(2)
                                        if showSparse, let result = availability.result(tagID: tag.id, identity: session.feedIdentity), result.state == .sparse {
                                            Text("\(result.countLowerBound) 条可见作品").font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if blocklist.names.contains(TagPolicy.normalize(tag.name)) { Image(systemName: "tag.slash").font(.caption2).foregroundStyle(.secondary) }
                                    Image(systemName: chosen ? "checkmark.circle.fill" : "plus").font(.caption)
                                        .foregroundStyle(chosen ? Color.blue : Color.secondary)
                                }.foregroundStyle(chosen ? Color.blue : Color.primary)
                                    .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 44)
                                    .padding(.vertical, 3)
                                    .background(chosen ? Color.blue.opacity(0.13) : AppTheme.secondarySurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                    .accessibilityIdentifier("tag-directory.tag.\(tag.id)")
                                    .accessibilityLabel(tag.name)
                                    .accessibilityValue((chosen ? "已选择" : "未选择") + (blocklist.names.contains(TagPolicy.normalize(tag.name)) ? "，已在本机屏蔽" : ""))
                            }
                        }
                        if store.loading {
                            HStack(spacing: 10) { ProgressView(); Text(store.tags.isEmpty ? "正在查找标签…" : "正在补充更多标签…").font(.caption).foregroundStyle(.secondary) }
                        } else if displayedTags.isEmpty && sparseCount > 0 {
                            Text("匹配标签的可见作品较少，点“显示全部”仍可选择。").font(.caption).foregroundStyle(.secondary)
                        } else if store.tags.isEmpty && store.reachedEnd {
                            Text("没有找到匹配标签，可尝试其他名称或首字母。").foregroundStyle(.secondary)
                        } else if store.tags.isEmpty && store.error == nil && store.onlineError == nil {
                            Text("这批杂项已隐藏，可以继续浏览。").font(.caption).foregroundStyle(.secondary)
                        }
                        if store.onlineError != nil {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("暂时无法补充站内结果，已有标签仍可选择。").font(.caption).foregroundStyle(.secondary)
                                Button("重试补充") { perform { await store.retryOnline(source: session) } }.buttonStyle(AppActionButtonStyle())
                            }
                        }
                        if store.error != nil {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("部分已保存标签暂未读出，仍可选择当前结果。").font(.caption).foregroundStyle(.secondary)
                                Button("重新读取") { perform { await store.reload(key: key, source: session) } }.buttonStyle(AppActionButtonStyle())
                            }
                        }
                        if store.cacheError != nil { Text("新标签已可选择，本机保存暂未完成。").font(.caption).foregroundStyle(.secondary) }
                        if !store.loading && !store.reachedEnd { Button("继续加载标签") { perform { await store.next(source: session) } }.buttonStyle(AppActionButtonStyle()) }
                    } else if valid { ProgressView("正在查找标签…") }
                    else { Text(MediaSearchText.validationMessage).font(.caption).foregroundStyle(.secondary) }
                        Text("当前显示 \(store.key == key ? displayedTags.count : 0) 个" + (!showSparse && sparseCount > 0 ? " · 已收起 \(sparseCount) 个少量作品标签" : "")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if store.key == key, !store.tags.isEmpty {
                            Button("核对更多候选的作品量") {
                                perform { await availability.verify(tags: store.tags, source: session) }
                            }.font(.caption).buttonStyle(AppActionButtonStyle())
                        }
                        DisclosureGroup("目录范围", isExpanded: $showDirectoryScope) {
                            Text("多选时作品须包含全部所选标签。完整标签库保留；按当前账号、全部媒体与全部时间核对后，少于 3 条可见作品的标签默认收起。尚未核对或请求失败的标签继续显示。每批仅核对有限候选，不代表全站总量。已隐藏纯符号、纯数字及年代类杂项。")
                                .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                        }.font(.caption).foregroundStyle(.secondary)
                    }.padding(16)
                }.scrollDismissesKeyboard(.interactively)
            }.navigationTitle("选择标签").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    AppToolbarItem(placement: .topBarLeading) { Menu { NavigationLink("标签库与同步设置") { LocalTagLibraryView().appNavigationBack() } } label: { Image(systemName: "ellipsis") }.buttonStyle(AppActionButtonStyle()).accessibilityLabel("标签设置") }
                    AppToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.buttonStyle(AppActionButtonStyle()) }
                }
                .task(id: key) {
                    guard valid else { store.cancel(); return }
                    await store.reload(key: key, source: session)
                }
                .task(id: availabilityKey) {
                    guard store.key == key, valid else { return }
                    await availability.verify(tags: store.tags, source: session)
                }
                .refreshable { if valid { await store.reload(key: key, source: session, forceRemote: true) } }
                .onChange(of: key) { _, _ in actionTask?.cancel(); actionTask = nil }
                .onDisappear { actionTask?.cancel(); actionTask = nil; store.cancel() }
                #if DEBUG && targetEnvironment(simulator)
                .overlay(alignment: .topLeading) {
                    if ProcessInfo.processInfo.arguments.contains("--qa-tag-availability55") {
                        let zero = availability.result(tagID: 42_002, identity: session.feedIdentity)
                        let value = "identity=\(session.feedIdentity);showSparse=\(showSparse);selected=\(selected.map(\.id));loaded=\(store.tags.count);visible=\(displayedTags.count);checked=\(availability.checkedCount(identity: session.feedIdentity));zero=\(String(describing: zero?.state));revision=\(availability.revision)"
                        Text(value).font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                            .accessibilityIdentifier("qa.tag-availability55").accessibilityValue(value)
                    }
                }
                #endif
        }
    }
    private func toggle(_ tag: SearchTag) {
        if selected.contains(where: { $0.id == tag.id }) { selected.removeAll { $0.id == tag.id }; selectionError = nil }
        else if selected.count < 8 { selected.append(tag); selectionError = nil }
        else { selectionError = "最多同时选择 8 个标签，可移除已有标签后再选。" }
    }
    private func perform(_ action: @escaping @MainActor () async -> Void) {
        actionTask?.cancel()
        let requestedKey = key
        actionTask = Task {
            guard !Task.isCancelled, requestedKey == key else { return }
            await action()
        }
    }
}

struct AuthorSearchPicker: View {
    @Binding var selected: Creator?
    @EnvironmentObject private var session: SiteSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var lookup = SearchLookupStore()
    @State private var text = ""
    private var keyword: String { MediaSearchText.normalized(text) }
    private var key: SearchLookupStore.Key { .init(mode: .author, text: keyword, identity: session.feedIdentity, blockedTags: []) }
    var body: some View {
        NavigationStack {
            List {
                Section { TextField("输入作者昵称", text: $text).textInputAutocapitalization(.never).autocorrectionDisabled() } footer: { Text("站点最多返回 20 位昵称候选；请细化昵称。选中作者后搜索作品，不伪造作者分页。") }
                if lookup.key == key {
                    ForEach(lookup.authors) { author in Button { selected = author; dismiss() } label: { HStack { AvatarView(name: author.username); Text("@" + author.username).foregroundStyle(.primary) } } }
                    if lookup.loading { ProgressView("搜索作者…") }
                    else if let error = lookup.error { Text(error).font(.caption).foregroundStyle(.secondary); Button("重试") { Task { await lookup.reload(key: key, source: session) } } }
                    else if lookup.authors.isEmpty && !keyword.isEmpty { Text("没有返回匹配作者").foregroundStyle(.secondary) }
                } else if !keyword.isEmpty {
                    if MediaSearchText.valid(keyword, mode: .author) { ProgressView("搜索作者…") }
                    else { Text(MediaSearchText.validationMessage).font(.caption).foregroundStyle(.secondary) }
                }
            }.navigationTitle("选择作者").navigationBarTitleDisplayMode(.inline).toolbar { AppToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.buttonStyle(AppActionButtonStyle()) } }
                .task(id: key) {
                    guard lookup.key != key else { return }; lookup.clear()
                    guard MediaSearchText.valid(keyword, mode: .author) else { return }
                    do { try await Task.sleep(for: .milliseconds(350)); try Task.checkCancellation() } catch { return }
                    await lookup.reload(key: key, source: session)
                }
        }
    }
}

struct TagWorksView: View {
    let name: String
    @EnvironmentObject private var session: SiteSession
    @State private var tag: SearchTag?
    @State private var loading = false
    @State private var error: String?
    init(name: String, id: Int?) { self.name = name; _tag = State(initialValue: id.flatMap { $0 > 0 ? SearchTag(id: $0, name: name) : nil }) }
    var body: some View {
        Group {
            if let tag { SearchWorksView(target: .tag(tag)) }
            else if loading { ProgressView("正在确认站点标签…") }
            else { FailureView(message: error ?? "标签编号尚未确认") { Task { await resolve() } } }
        }.task(id: session.feedIdentity) { if tag == nil { await resolve() } }
    }
    private func resolve() async {
        guard !loading else { return }; loading = true; error = nil
        defer { loading = false }; let identity = session.feedIdentity
        do {
            let result = try await session.exactTag(name: name)
            guard identity == session.feedIdentity, !Task.isCancelled else { return }
            if let result { tag = result } else { error = "站点暂未确认这个标签的编号，请稍后重试；没有发起无条件作品查询。" }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
