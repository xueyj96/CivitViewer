import SwiftUI

struct BrowsingHistoryView: View {
    @EnvironmentObject private var session: SiteSession
    @ObservedObject private var history = BrowsingHistory.shared
    @ObservedObject private var blocklist = TagBlocklist.shared
    @ObservedObject private var authorBlocklist = AuthorBlocklist.shared
    @State private var kind: MediaKind = .all
    @State private var query = ""
    @State private var limit = 30
    @State private var verified: [Int: MediaItem] = [:]
    @State private var checked = Set<Int>()
    @State private var loading = false
    @State private var loadError = false
    @State private var validatedIdentity: String?
    @State private var clearConfirmation = false
    @State private var request: HistoryPlaybackRequest?
    private var context: HistoryContext? { history.context(ownerID: session.tagLibraryOwnerID) }
    private var matching: [HistoryRecord] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return history.records.filter { record in
            !authorBlocklist.blocks(record) &&
            (kind == .all || record.kind == kind) &&
            (keyword.isEmpty || (record.authorName ?? "").localizedCaseInsensitiveContains(keyword) || String(record.id).contains(keyword))
        }
    }
    private var page: [HistoryRecord] { Array(matching.prefix(limit)) }
    private var visible: [HistoryRecord] {
        page.filter { record in
            guard !authorBlocklist.blocks(record) else { return false }
            guard let item = verified[record.id] else { return blocklist.names.isEmpty }
            return permitted(item) && !authorBlocklist.blocks(item)
        }
    }
    private var dayGroups: [(Date, [HistoryRecord])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: visible) { calendar.startOfDay(for: $0.viewedAt) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0] ?? []) }
    }
    private var loadKey: String { "\(session.tagLibraryIdentity):\(session.feedIdentity):\(context?.generation ?? -1):" + page.map { String($0.id) }.joined(separator: ",") }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 15) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(history.records.count)").font(.system(size: 36, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("条最近浏览").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "clock.arrow.circlepath").font(.title2).foregroundStyle(.blue)
                    }
                    Toggle("记录浏览历史", isOn: Binding(get: { history.recordingEnabled }, set: { value in
                        if let context { history.setRecordingEnabled(value, context: context) }
                    })).disabled(context == nil)
                    Text(history.recordingEnabled ? "画面显示后停留 2 秒记入，保留 30 天，最多 5,000 条。" : "已暂停新增记录和保存播放位置，已有历史保留。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !authorBlocklist.entries.isEmpty {
                        Text("本机作者屏蔽只隐藏对应历史条目；记录仍保留，取消屏蔽后可重新显示。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 20))

                if !history.checkpoints.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("接着看").font(.headline)
                        ForEach(history.checkpoints, id: \.lane) { checkpoint in
                            Button {
                                if let context { request = .init(checkpoint: checkpoint, context: context, resumePosition: history.resumePosition(for: checkpoint.focusedID)) }
                            } label: {
                                HStack(spacing: 13) {
                                    Image(systemName: checkpoint.lane == .following ? "person.2" : "play.rectangle").font(.title3).frame(width: 26)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(checkpoint.lane.title + "时间线").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                        Text(checkpoint.filter.effectiveKind.chineseTitle + " · " + checkpoint.updatedAt.formatted(.relative(presentation: .named).locale(Locale(identifier: "zh_Hans_CN")))).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(); Image(systemName: "play.circle.fill").font(.title2)
                                }.padding(14).background(.background, in: RoundedRectangle(cornerRadius: 15))
                            }.buttonStyle(.plain).foregroundStyle(.blue).disabled(context == nil)
                        }
                    }
                }

                Picker("历史媒体类型", selection: $kind) { ForEach(MediaKind.allCases) { Text($0.chineseTitle).tag($0) } }.pickerStyle(.segmented)
                if let error = history.error {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(error).font(.subheadline)
                        Button("重新读取") { Task { await history.retry(ownerID: session.tagLibraryOwnerID, identity: session.tagLibraryIdentity) } }
                    }
                }
                if history.ready && matching.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "还没有浏览记录" : "没有匹配的浏览记录", systemImage: "clock", description: Text(query.isEmpty ? "在作品画面停留两秒，之后可以从这里找回。" : "可按作者名或作品编号查找。"))
                }
                ForEach(dayGroups, id: \.0) { day, rows in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(dayTitle(day)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        VStack(spacing: 0) {
                            ForEach(rows) { record in
                                Button { open(record) } label: { historyRow(record) }.buttonStyle(.plain).accessibilityIdentifier("history.item.\(record.id)")
                                    .contextMenu {
                                        Button("从历史中删除", systemImage: "trash", role: .destructive) {
                                            if let context { history.remove(ids: [record.id], context: context) }
                                        }
                                    }
                                if record.id != rows.last?.id { Divider().padding(.leading, 86) }
                            }
                        }.background(.background, in: RoundedRectangle(cornerRadius: 18))
                    }
                }
                if loading { ProgressView("正在核对作品…").frame(maxWidth: .infinity) }
                if page.count > visible.count {
                    Text("\(page.count - visible.count) 项因屏蔽标签或标签待核实暂不展示。").font(.caption).foregroundStyle(.secondary)
                }
                if loadError {
                    Button("作品信息暂未取得，点此重试") { Task { await hydrate(retry: true) } }.font(.subheadline)
                }
                if limit < matching.count { Button("展开更多记录") { limit += 30 }.frame(maxWidth: .infinity).padding(12) }
                Text("浏览记录只保存在当前账号的本机空间。打开作品时重新核对账号可见范围；清理历史不会删除收藏或缓存文件。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(18)
        }.background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("最近浏览").navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, prompt: "作者名或作品编号")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空", role: .destructive) { clearConfirmation = true }.disabled(history.records.isEmpty || context == nil)
                }
            }
            .confirmationDialog("清空本机浏览记录与接着看位置？", isPresented: $clearConfirmation, titleVisibility: .visible) {
                Button("清空浏览历史", role: .destructive) { if let context { history.clear(context: context) } }
            } message: { Text("仅清理当前账号的浏览历史。收藏、离线文件和时间线缓存会保留。") }
            .task(id: loadKey) { await hydrate() }
            .onChange(of: session.tagLibraryIdentity) { _, _ in verified = [:]; checked = []; request = nil }
            .onChange(of: session.feedIdentity) { _, _ in verified = [:]; checked = [] }
            .onChange(of: kind) { _, _ in limit = 30 }
            .onChange(of: query) { _, _ in limit = 30 }
            .fullScreenCover(item: $request) { HistoryPlaybackView(request: $0) }
    }

    private func historyRow(_ record: HistoryRecord) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Color(uiColor: .secondarySystemGroupedBackground)
                if let item = verified[record.id], let url = item.isVideo ? item.posterURL : item.mediaURL,
                   permitted(item) {
                    CachedImage(url: url).blur(radius: ((session.account?.blurNsfw ?? true) && ((item.browsingLevel ?? 1) & 28 != 0)) ? 20 : 0)
                } else { Image(systemName: record.kind == .video ? "play.rectangle" : "photo").foregroundStyle(.secondary) }
                if record.kind == .video { Image(systemName: "play.fill").font(.caption).foregroundStyle(.white).padding(7).background(.black.opacity(0.4), in: Circle()) }
            }.frame(width: 58, height: 74).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text(record.authorName.map { "@" + $0 } ?? "作品 #\(record.id)").font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(record.kind.chineseTitle + " · " + record.viewedAt.formatted(.dateTime.locale(Locale(identifier: "zh_Hans_CN")).hour().minute())).font(.caption).foregroundStyle(.secondary)
                if let position = PlaybackResumePolicy.position(position: record.positionSeconds, duration: record.durationSeconds), position >= 1 {
                    Text("看到 " + clock(position) + " / " + clock(record.durationSeconds ?? 0)).font(.caption.monospacedDigit()).foregroundStyle(.blue)
                } else if checked.contains(record.id) && verified[record.id] == nil {
                    Text("当前不可见或暂不可用").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 2)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }.padding(14).contentShape(Rectangle())
    }
    private func open(_ record: HistoryRecord) {
        guard let context else { return }
        let ids = page.map(\.id)
        request = .init(ids: ids, focusedID: record.id, context: context, resumePosition: history.resumePosition(for: record.id))
    }
    private func permitted(_ item: MediaItem) -> Bool {
        !authorBlocklist.blocks(item) &&
        !HistoryMediaPolicy.ordered([item], ids: [item.id], blockedTags: blocklist.names, allowedMask: session.account?.browsingLevel ?? 1).isEmpty
    }
    private func hydrate(retry: Bool = false) async {
        guard let context else { return }
        let identity = session.tagLibraryIdentity, visibility = session.feedIdentity
        let validation = identity + ":" + visibility
        if validatedIdentity != validation { verified = [:]; checked = []; validatedIdentity = validation }
        let ids = page.map(\.id).filter { retry || !checked.contains($0) }
        guard !ids.isEmpty else { return }
        loading = true; loadError = false
        defer { if identity == session.tagLibraryIdentity, visibility == session.feedIdentity { loading = false } }
        do {
            for start in stride(from: 0, to: ids.count, by: 30) {
                try Task.checkCancellation()
                let batch = Array(ids[start..<min(ids.count, start + 30)])
                let media = try await session.mediaItems(ids: batch, includeTags: true)
                guard history.accepts(context), identity == session.tagLibraryIdentity, visibility == session.feedIdentity, !Task.isCancelled else { return }
                let allowed = HistoryMediaPolicy.ordered(media, ids: batch, blockedTags: [], allowedMask: session.account?.browsingLevel ?? 1)
                for id in batch { verified[id] = nil }
                for item in allowed { verified[item.id] = item }
                checked.formUnion(batch)
            }
        } catch is CancellationError {} catch {
            if history.accepts(context), identity == session.tagLibraryIdentity, visibility == session.feedIdentity {
                loadError = true; LocalDiagnosticsStore.shared.note(area: .restore, code: .loadFailed)
            }
        }
    }
    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "今天" }
        if Calendar.current.isDateInYesterday(day) { return "昨天" }
        return day.formatted(.dateTime.locale(Locale(identifier: "zh_Hans_CN")).month().day())
    }
    private func clock(_ value: Double) -> String { let n = Int(max(0, value)); return String(format: "%d:%02d", n / 60, n % 60) }
}

struct HistoryPlaybackView: View {
    let request: HistoryPlaybackRequest
    var onLatest: (() -> Void)? = nil
    @EnvironmentObject private var session: SiteSession
    @Environment(\.ordinaryColorScheme) private var ordinaryScheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var history = BrowsingHistory.shared
    @ObservedObject private var blocklist = TagBlocklist.shared
    @ObservedObject private var authorBlocklist = AuthorBlocklist.shared
    @State private var items: [MediaItem] = []
    @State private var focused: Int?
    @State private var creator: CreatorRoute?
    @State private var loading = false
    @State private var message: String?
    @State private var navigationVisible = true
    private var currentItems: [MediaItem] {
        HistoryMediaPolicy.ordered(items, ids: request.ids, blockedTags: blocklist.names, filter: request.filter,
                                   followingIDs: request.lane == .following ? session.following : nil, allowedMask: session.account?.browsingLevel ?? 1)
            .filter { !authorBlocklist.blocks($0) }
    }
    private var resumePositions: [Int: Double] {
        if let record = history.records.first(where: { $0.id == request.focusedID }), record.durationSeconds != nil {
            return PlaybackResumePolicy.position(position: record.positionSeconds, duration: record.durationSeconds).map { [request.focusedID: $0] } ?? [:]
        }
        return request.resumePosition.map { [request.focusedID: $0] } ?? [:]
    }
    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                if !currentItems.isEmpty {
                    MediaDeck(items: currentItems, focused: $focused, initialID: request.focusedID,
                              isVisible: navigationVisible, showsLoadMore: false, onAuthor: { creator = $0 },
                              historyCheckpoint: { item in
                        guard let lane = request.lane, let filter = request.filter else { return nil }
                        return TimelineCheckpoint.window(lane: lane, filter: filter, items: currentItems, focusedID: item.id)
                    }, resumePositions: resumePositions,
                              endAction: onLatest == nil ? nil : latest) {}
                } else if loading { ProgressView("正在核对作品…").tint(.white).foregroundStyle(.white).frame(maxHeight: .infinity) }
                else {
                    ContentUnavailableView { Label("这段内容暂不可用", systemImage: "photo.badge.exclamationmark") } description: {
                        Text(message ?? "作品可能已不在当前可见范围，或被当前标签设置屏蔽。浏览记录会保留。")
                    } actions: {
                        Button("重试") { Task { await load() } }
                        if onLatest != nil { Button("加载当前最新内容", action: latest) }
                    }.foregroundStyle(.white)
                }
                if !currentItems.isEmpty && !currentItems.contains(where: { $0.id == request.focusedID }) {
                    Text("原作品当前不可见，已定位到相邻可见作品").font(.caption).padding(10).foregroundStyle(.white).background(.black.opacity(0.7), in: Capsule()).padding(.top, 10)
                }
            }.toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭浏览记录") }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text(request.lane.map { $0.title + " · 接着看" } ?? "最近浏览").font(.headline)
                        if let filter = request.filter { Text(filter.effectiveKind.chineseTitle + " · " + filter.sortTitle).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                if onLatest != nil { ToolbarItem(placement: .topBarTrailing) { Button("最新", action: latest).accessibilityLabel("加载当前最新时间线") } }
            }.navigationBarTitleDisplayMode(.inline)
                .navigationDestination(item: $creator) { CreatorView(creator: $0.creator, initialKind: $0.kind) }
                .onAppear { navigationVisible = true }.onDisappear { navigationVisible = false }
        }.preferredColorScheme(creator == nil ? .dark : ordinaryScheme).tint(.white)
            .task { await load() }
            .onChange(of: session.tagLibraryIdentity) { _, _ in items = []; dismiss() }
            .onChange(of: history.generation) { _, _ in if !history.accepts(request.context) { items = []; dismiss() } }
    }
    private func latest() { onLatest?(); dismiss() }
    private func load() async {
        guard !loading, history.accepts(request.context) else { return }
        loading = true; message = nil
        let identity = session.tagLibraryIdentity
        defer { loading = false }
        do {
            let followingIDs = request.lane == .following ? try await session.refreshFollowingIDs() : nil
            let media = try await session.resumeMediaItems(ids: request.ids, followingIDs: followingIDs) {
                !Task.isCancelled && identity == session.tagLibraryIdentity && history.accepts(request.context)
            }
            guard !Task.isCancelled, identity == session.tagLibraryIdentity, history.accepts(request.context) else { return }
            if let filter = request.filter {
                items = try await session.enrichRestoredVideoDurations(media, filter: filter) {
                    !Task.isCancelled && identity == session.tagLibraryIdentity && history.accepts(request.context)
                }
            } else { items = media }
            focused = currentItems.contains(where: { $0.id == request.focusedID }) ? request.focusedID : currentItems.first?.id
        } catch is CancellationError {} catch {
            guard identity == session.tagLibraryIdentity, history.accepts(request.context) else { return }
            message = "连接或账号暂不可用，请联网后重试。历史位置仍保留。"
            LocalDiagnosticsStore.shared.note(area: .restore, code: .loadFailed)
        }
    }
}
