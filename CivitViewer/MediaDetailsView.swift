import SwiftUI

struct MediaDetailsView: View {
    let item: MediaItem
    @EnvironmentObject private var session: SiteSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var blocklist = TagBlocklist.shared
    @ObservedObject private var authorBlocklist = AuthorBlocklist.shared
    @State private var tags: [String]?
    @State private var tagIDs: [String: Int]
    @State private var selected = Set<String>()
    @State private var tagsExpanded = false
    @State private var loading = false
    @State private var preparingSearch = false
    @State private var searchTask: Task<Void, Never>?
    @State private var searchDraft: MediaSearchCriteria?
    @State private var error: String?
    @State private var authorBlockError: String?
    @State private var authorBlockWorking = false
    @State private var authorBlockTask: Task<Void, Never>?
    @State private var authorBlockRequestID: UUID?
    @State private var displayedItemID: Int
    @State private var posterFailed = false
    @State private var posterRetry = 0
    private var blurPreview: Bool { (session.account?.blurNsfw ?? true) && ((item.browsingLevel ?? 1) & 28 != 0) }
    init(item: MediaItem) {
        self.item = item; _tags = State(initialValue: item.tagNames?.sorted())
        _tagIDs = State(initialValue: Self.ids(item.tags))
        _displayedItemID = State(initialValue: item.id)
    }
    private static func ids(_ tags: [MediaTag]?) -> [String: Int] {
        Dictionary((tags ?? []).compactMap { value in
            guard let name = value.name, let id = value.id, id > 0 else { return nil }
            return (TagPolicy.normalize(name), id)
        }, uniquingKeysWith: { first, _ in first })
    }
    private var eligibleTags: [String] { (tags ?? []).filter { TagDirectoryQuality.includes($0) } }
    private var visibleTags: [String] {
        let all = eligibleTags
        guard !tagsExpanded, all.count > 12 else { return all }
        let first = Array(all.prefix(12))
        return all.filter { first.contains($0) || selected.contains($0) }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text((item.isVideo ? "视频" : "图片") + " · #" + String(item.id))
                                .font(.headline).accessibilityIdentifier("details.summary")
                            if let author = item.username {
                                Text("@" + author).font(.subheadline).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 8) {
                                if item.offlineMediaURL != nil {
                                    Label("本地副本", systemImage: "internaldrive")
                                }
                                if blockedAuthorForItem != nil {
                                    Text("作者已在本机屏蔽")
                                }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Menu {
                            if let blocked = blockedAuthorForItem {
                                Button("取消本机屏蔽", role: .destructive) {
                                    authorBlocklist.remove(id: blocked.id); authorBlockError = nil
                                }
                            } else if item.username != nil {
                                Button(authorBlockWorking ? "正在核验…" : "屏蔽此作者", systemImage: "person.crop.circle.badge.xmark") {
                                    guard !authorBlockWorking else { return }
                                    let expectedID = displayedItemID, identity = session.feedIdentity
                                    let requestID = UUID()
                                    authorBlockTask?.cancel()
                                    authorBlockRequestID = requestID
                                    authorBlockTask = Task { await blockCurrentAuthor(itemID: expectedID, identity: identity, requestID: requestID) }
                                }.disabled(authorBlockWorking)
                            } else {
                                Button("无法屏蔽：作者身份不可核验") {}.disabled(true)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .buttonStyle(AppActionButtonStyle(tone: .neutral))
                        .accessibilityLabel(blockedAuthorForItem == nil ? "更多作者操作" : "更多作者操作，作者已屏蔽")
                        .accessibilityIdentifier("details.more")
                    }

                    preview

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text("站点标签").font(.headline)
                            Text("已选 \(selected.count) / 8").font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("details.selection.count")
                            Spacer(minLength: 0)
                            Button {
                                guard !loading, !preparingSearch else { return }
                                Task { await refresh() }
                            } label: {
                                Group {
                                    if loading { ProgressView().controlSize(.small) }
                                    else { Image(systemName: "arrow.clockwise") }
                                }
                            }
                            .buttonStyle(AppActionButtonStyle(tone: .neutral))
                            .disabled(loading || preparingSearch)
                            .accessibilityLabel("重新读取标签")
                            .accessibilityIdentifier("details.refresh")
                        }
                        if let tags {
                            if eligibleTags.isEmpty {
                                Text(tags.isEmpty ? "站点返回的标签列表为空" : "没有可展示的标签")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            } else {
                                TagPillLayout(spacing: 6) {
                                    ForEach(visibleTags, id: \.self) { tag in tagButton(tag) }
                                }
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("details.tags")
                                if eligibleTags.count > 12 {
                                    Button(tagsExpanded ? "收起标签" : "显示全部标签（\(eligibleTags.count)）") {
                                        tagsExpanded.toggle()
                                    }
                                    .buttonStyle(AppActionButtonStyle(tone: .neutral))
                                    .accessibilityIdentifier("details.tags.expand")
                                }
                            }
                        } else if !loading {
                            Text("标签尚未取得").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text("点选标签组合搜索；长按可屏蔽或单独搜索。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if loading { ProgressView("正在读取作品标签…").font(.caption) }
                    if let error { Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    if let authorBlockError { Text(authorBlockError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppTheme.spacing)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }.background(Color(uiColor: .systemBackground)).disabled(preparingSearch)
                .safeAreaInset(edge: .bottom) {
                    if !selected.isEmpty { searchBar }
                }
                .navigationTitle("作品详情").navigationBarTitleDisplayMode(.inline)
                .toolbar { AppToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.buttonStyle(AppActionButtonStyle()) } }
                .navigationDestination(item: $searchDraft) { SearchView(initialCriteria: $0) }
                .task { if tags == nil { await refresh() } }
        }.ordinaryAppearance()
            .onAppear { notePosterRoute() }
            .onChange(of: session.feedIdentity) { _, _ in
                searchTask?.cancel(); authorBlockTask?.cancel(); authorBlockRequestID = nil; authorBlockWorking = false
                tags = nil; tagIDs = [:]; selected = []; tagsExpanded = false
                error = "账号内容范围已变更，请重新读取标签。"
            }
            .onChange(of: item.id) { _, newID in
                displayedItemID = newID; authorBlockTask?.cancel(); authorBlockRequestID = nil; authorBlockWorking = false
                notePosterRoute()
            }
            .onDisappear { searchTask?.cancel(); authorBlockTask?.cancel() }
    }
    @ViewBuilder private var preview: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            Group {
            if item.isVideo, let source = item.mediaURL {
                CachedPoster(source: source, declared: item.posterURL, active: false, fit: true,
                    retryToken: posterRetry, allowLocalExtraction: true, diagnosticWorkID: item.id,
                    onFailure: { posterFailed = $0 })
            } else if !item.isVideo, let imageURL = item.mediaURL {
                CachedImage(url: imageURL, fit: true, allowsRetry: false)
            } else {
                Image(systemName: item.isVideo ? "play.rectangle" : "photo")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            }.blur(radius: blurPreview ? 24 : 0)
            if posterFailed {
                VStack {
                    Spacer()
                    Button("重试封面") { posterRetry += 1 }
                        .buttonStyle(AppActionButtonStyle())
                        .accessibilityIdentifier("details.poster.retry")
                }.padding(8)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.isVideo ? "视频封面" : "作品预览")
        .accessibilityIdentifier("details.preview")
    }
    private func notePosterRoute() {
        let route: PosterDiagnosticStage = item.mediaURL == nil ? .detailsUnavailable :
            (item.isVideo ? .detailsVideo : .detailsBitmap)
        guard let context = PlaybackFailureDiagnostic(workID: item.id, posterRoute: route,
            sourceURL: item.mediaURL, declaredURL: item.posterURL) else { return }
        LocalDiagnosticsStore.shared.note(area: .thumbnail, code: .posterOpened, playback: context)
    }
    private var blockedAuthorForItem: BlockedAuthor? {
        if let id = item.creatorID { return authorBlocklist.entries.first(where: { $0.id == id }) }
        guard let username = item.username else { return nil }
        let handle = AuthorHandlePolicy.normalize(username)
        guard authorBlocklist.blockedHandles.contains(handle) else { return nil }
        return authorBlocklist.entries.first(where: { AuthorHandlePolicy.normalize($0.username) == handle })
    }
    @MainActor private func blockCurrentAuthor(itemID: Int, identity: String, requestID: UUID) async {
        guard !Task.isCancelled, !authorBlockWorking, authorBlockRequestID == requestID,
              displayedItemID == itemID, item.id == itemID else { return }
        authorBlockWorking = true; authorBlockError = nil
        defer {
            if authorBlockRequestID == requestID { authorBlockWorking = false; authorBlockRequestID = nil }
        }
        guard let username = item.username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty else {
            authorBlockError = "作品没有可核验的作者用户名，不能屏蔽匿名作者。"; return
        }
        do {
            let creator: Creator
            if let creatorID = item.creatorID, creatorID > 0 {
                creator = Creator(id: creatorID, username: username, image: nil)
            } else {
                let resolved = try await session.creator(username: username)
                guard identity == session.feedIdentity, !Task.isCancelled,
                      authorBlockRequestID == requestID, displayedItemID == itemID, item.id == itemID else { return }
                guard resolved.username == username else {
                    authorBlockError = "站点返回的作者用户名与作品不完全匹配，未添加屏蔽。"; return
                }
                creator = resolved
            }
            guard identity == session.feedIdentity, !Task.isCancelled,
                  authorBlockRequestID == requestID, displayedItemID == itemID, item.id == itemID else { return }
            guard authorBlocklist.add(creator) else {
                authorBlockError = authorBlocklist.error ?? "无法将此作者加入本机屏蔽名单。"; return
            }
            dismiss()
        } catch is CancellationError {
            return
        } catch {
            guard identity == session.feedIdentity, !Task.isCancelled,
                  authorBlockRequestID == requestID, displayedItemID == itemID, item.id == itemID else { return }
            authorBlockError = "无法核验作者资料：" + error.localizedDescription
        }
    }
    private var searchBar: some View {
        HStack(spacing: 8) {
            Button("清空") { if !preparingSearch { selected = [] } }
                .buttonStyle(AppActionButtonStyle(tone: .neutral))
                .disabled(preparingSearch)
            Button {
                guard !preparingSearch, !loading else { return }
                searchTask?.cancel()
                searchTask = Task { await prepareSearch() }
            } label: {
                HStack(spacing: 8) {
                    if preparingSearch { ProgressView() }
                    Label("组合搜索 · \(selected.count)", systemImage: "magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(AppActionButtonStyle(tone: .accent))
            .disabled(selected.isEmpty || preparingSearch || loading)
                .accessibilityIdentifier("details.search")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(Color(uiColor: .systemBackground).opacity(0.96))
    }
    private func tagButton(_ tag: String) -> some View {
        let chosen = selected.contains(tag)
        let blocked = blocklist.names.contains(tag)
        return Button {
            guard !preparingSearch else { return }
            if selected.contains(tag) { selected.remove(tag); error = nil }
            else if selected.count < 8 { selected.insert(tag); error = nil }
            else { error = "最多组合 8 个标签，可先取消已有选择。" }
        } label: {
            HStack(spacing: 5) {
                if chosen { Image(systemName: "checkmark").font(.caption.weight(.semibold)) }
                Text(tag).font(.subheadline).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if blocked { Image(systemName: "tag.slash").font(.caption2) }
            }.padding(.horizontal, 12).padding(.vertical, 9)
                .foregroundStyle(chosen ? Color.blue : (blocked ? Color.secondary : Color.primary))
                .background(chosen ? Color.blue.opacity(0.12) : Color(uiColor: .secondarySystemBackground), in: Capsule())
                .overlay(Capsule().stroke(chosen ? Color.blue.opacity(0.25) : .clear, lineWidth: 1))
        }.buttonStyle(.plain).accessibilityIdentifier("details.tag.\(tag)")
            .accessibilityLabel(tag).accessibilityValue(chosen ? "已选入组合搜索" : "未选择")
            .contextMenu {
                Button(blocked ? "撤销屏蔽" : "屏蔽此标签", systemImage: blocked ? "tag" : "tag.slash") {
                    guard !preparingSearch else { return }
                    if blocked { blocklist.remove(tag); error = nil }
                    else if !blocklist.add(tag) { error = "无法加入屏蔽列表：最多 100 个标签，每个最多 80 字。" }
                }.disabled(preparingSearch)
                Button("仅用此标签组合搜索", systemImage: "magnifyingglass") {
                    guard !preparingSearch, !loading else { return }
                    selected = [tag]; searchTask?.cancel(); searchTask = Task { await prepareSearch() }
                }.disabled(preparingSearch || loading)
            }
    }
    private func prepareSearch() async {
        guard !Task.isCancelled, !preparingSearch, !selected.isEmpty else { return }
        preparingSearch = true; error = nil
        defer { preparingSearch = false }
        let identity = session.feedIdentity, names = selected.sorted()
        do {
            var resolved: [SearchTag] = []
            for name in names {
                try Task.checkCancellation()
                if let id = tagIDs[name] { resolved.append(.init(id: id, name: name)) }
                else if let tag = try await session.exactTag(name: name) { resolved.append(tag) }
                else { throw ClientError.format("站点暂未确认标签编号，请重新读取标签后重试。") }
            }
            guard identity == session.feedIdentity, !Task.isCancelled, selected == Set(names) else { return }
            searchDraft = .init(tags: resolved)
        } catch is CancellationError {} catch { if identity == session.feedIdentity { self.error = error.localizedDescription } }
    }
    private func refresh() async {
        guard !loading, !preparingSearch else { return }; loading = true; error = nil
        defer { loading = false }
        let identity = session.feedIdentity
        do {
            guard let value = try await session.mediaItem(id: item.id), let names = value.tagNames else { error = "站点未返回可确认的标签，作品可能暂不可访问；请稍后重试。"; return }
            guard identity == session.feedIdentity, !Task.isCancelled else { return }
            tags = names.sorted(); tagIDs = Self.ids(value.tags); selected.formIntersection(names)
        } catch { if !Task.isCancelled { self.error = "标签读取失败：" + error.localizedDescription } }
    }
}

struct TagPillLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 320
        return CGSize(width: width, height: arrangement(width: width, subviews: subviews).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        for (view, placement) in zip(subviews, result.frames) {
            view.place(at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y), proposal: ProposedViewSize(placement.size))
        }
    }
    private func arrangement(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        let width = max(1, width)
        var frames: [CGRect] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let ideal = view.sizeThatFits(.unspecified)
            let size = view.sizeThatFits(ProposedViewSize(width: min(width, ideal.width), height: nil))
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (frames, frames.isEmpty ? 0 : y + rowHeight)
    }
}

struct CreatorBiographyView: View {
    let creator: Creator
    var onCollapse: (() -> Void)? = nil
    @EnvironmentObject private var session: SiteSession
    @State private var value: CreatorBiography?
    @State private var error: String?
    @State private var loading = false
    @State private var loadedIdentity: String?
    @State private var expanded = false
    @State private var revision = 0
    @State private var requestedIdentity: String?
    private var text: String { BiographyText.plain(value?.profile?.bio ?? "") }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if loading { ProgressView("读取简介…").font(.caption) }
            else if let error { Text(error).font(.caption).foregroundStyle(.secondary); Button("重试简介") { Task { await load() } }.font(.caption) }
            else if value == nil { Text("简介尚未取得").font(.caption).foregroundStyle(.secondary); Button("读取简介") { Task { await load() } }.font(.caption) }
            else if value?.blockedByThem == true { Text("作者简介当前不可见").font(.caption).foregroundStyle(.secondary) }
            else { CreatorBiographyContent(text: text, onCollapse: onCollapse) }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .task(id: session.feedIdentity) { if loadedIdentity != session.feedIdentity { await load() } }
    }
    private func load() async {
        let identity = session.feedIdentity
        guard !loading || requestedIdentity != identity else { return }
        revision += 1; let request = revision; requestedIdentity = identity
        loading = true; error = nil
        if loadedIdentity != identity { value = nil; expanded = false }
        defer { if request == revision { loading = false } }
        do {
            let result = try await session.creatorBiography(creator)
            guard request == revision, identity == session.feedIdentity, !Task.isCancelled else { return }
            value = result; loadedIdentity = identity
        } catch { if request == revision && identity == session.feedIdentity && !Task.isCancelled { self.error = "简介暂时无法读取：" + error.localizedDescription } }
    }
}

/// Full-width, native biography text shared by the loaded creator view and
/// controlled layout previews. Overflow beyond two lines is detected from the
/// text's laid-out height at the currently proposed width, so font and width
/// changes remeasure.
struct CreatorBiographyContent: View {
    let text: String
    var onCollapse: (() -> Void)? = nil
    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var collapsedHeight: CGFloat = 0

    private var hasOverflow: Bool { fullHeight > collapsedHeight + 1 }
    private var attributedText: AttributedString { Self.linkedText(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !text.isEmpty {
                Text(attributedText)
                    .font(.subheadline)
                    .lineLimit(expanded ? nil : 2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("creator.biography.body")
                    .overlay {
                        ZStack(alignment: .topLeading) {
                            Text(attributedText)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .hidden().accessibilityHidden(true)
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.preference(key: BiographyHeightKey.self, value: ["full": proxy.size.height])
                                    }
                                }
                            Text(attributedText)
                                .font(.subheadline).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .hidden().accessibilityHidden(true)
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.preference(key: BiographyHeightKey.self, value: ["collapsed": proxy.size.height])
                                    }
                                }
                        }.allowsHitTesting(false).accessibilityHidden(true)
                    }

                if hasOverflow {
                    Button(expanded ? "收起" : "展开") {
                        let wasExpanded = expanded
                        withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                        if wasExpanded { onCollapse?() }
                    }
                    .font(.caption.weight(.medium))
                    .tint(.blue)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("creator.biography.toggle")
                    .accessibilityValue(expanded ? "已展开" : "已收起")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: text) { _, _ in expanded = false; fullHeight = 0; collapsedHeight = 0 }
        .onPreferenceChange(BiographyHeightKey.self) { values in
            if let full = values["full"], abs(fullHeight - full) > 0.5 { fullHeight = full }
            if let collapsed = values["collapsed"], abs(collapsedHeight - collapsed) > 0.5 { collapsedHeight = collapsed }
        }
    }

    /// Add native Text links only for URLs accepted by the existing policy.
    /// Zero-width break opportunities keep a long URL inside narrow screens;
    /// the explicit link attribute still targets the original safe URL.
    private static func linkedText(_ source: String) -> AttributedString {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return AttributedString(source)
        }
        let matches = detector.matches(in: source, range: NSRange(source.startIndex..., in: source))
        var result = AttributedString()
        var cursor = source.startIndex
        for match in matches {
            guard let range = Range(match.range, in: source),
                  let raw = match.url?.absoluteString,
                  let safe = BiographyText.safeURL(raw), range.lowerBound >= cursor else { continue }
            result.append(AttributedString(String(source[cursor..<range.lowerBound])))
            let originalURL = String(source[range])
            var display = ""
            for (index, character) in originalURL.enumerated() {
                if index > 0 && index % 12 == 0 { display.append("\u{200B}") }
                display.append(character)
            }
            var linked = AttributedString(display)
            linked.link = safe
            result.append(linked)
            cursor = range.upperBound
        }
        result.append(AttributedString(String(source[cursor...])))
        return result
    }
}

private struct BiographyHeightKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
