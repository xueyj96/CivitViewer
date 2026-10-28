import SwiftUI

private enum OfflineFilter: String, CaseIterable, Identifiable {
    case all = "全部状态", ready = "已下载", pending = "未下载", localOnly = "已取消收藏", unknown = "待核对", failed = "下载失败"
    var id: Self { self }
    func includes(_ record: OfflineRecord) -> Bool {
        switch self {
        case .all: true
        case .ready: record.fileState == .ready
        case .pending: record.fileState == .pending
        case .localOnly: record.cloudState == .localOnly
        case .unknown: record.cloudState == .unknown
        case .failed: record.fileState == .failed
        }
    }
}
private enum OfflineSort: String, CaseIterable, Identifiable {
    case newest = "最新保存", largest = "占用最大", oldest = "最早保存", unused = "最久未打开"
    var id: Self { self }
}

struct OfflineStorageView: View {
    @EnvironmentObject private var session: SiteSession
    @Environment(\.ordinaryColorScheme) private var ordinaryScheme
    @ObservedObject private var library = OfflineLibrary.shared
    @ObservedObject private var blocklist = TagBlocklist.shared
    @ObservedObject private var authorBlocklist = AuthorBlocklist.shared
    @State private var editMode: EditMode = .inactive
    @State private var kind: MediaKind = .all
    @State private var filter: OfflineFilter = .all
    @State private var sort: OfflineSort = .newest
    @State private var selected = Set<Int>()
    @State private var confirmDelete = false
    @State private var confirmClean = false
    @State private var confirmAll = false
    @State private var viewerItem: MediaItem?
    @State private var viewerItems: [MediaItem] = []
    @State private var focused: Int?
    @State private var creator: CreatorRoute?
    private var visible: [OfflineRecord] {
        library.records.filter { filter.includes($0) && (kind == .all || (kind == .video ? $0.video : !$0.video)) && TagPolicy.verdict(names: $0.tagNames, blocked: blocklist.names) == .allowed && !authorIsBlocked($0) }.sorted {
            switch sort {
            case .largest: $0.bytes == $1.bytes ? $0.id > $1.id : $0.bytes > $1.bytes
            case .oldest: ($0.savedAt ?? .distantPast) < ($1.savedAt ?? .distantPast)
            case .unused: ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast)
            case .newest: ($0.savedAt ?? .distantPast) == ($1.savedAt ?? .distantPast) ? $0.id > $1.id : ($0.savedAt ?? .distantPast) > ($1.savedAt ?? .distantPast)
            }
        }
    }
    private var playable: [MediaItem] {
        guard let directory = library.directory else { return [] }
        return visible.filter { $0.fileState == .ready }.map { $0.media(in: directory) }
    }
    private var visibleViewerItems: [MediaItem] { viewerItems.filter { !authorBlocklist.blocks($0) } }
    private func authorIsBlocked(_ record: OfflineRecord) -> Bool {
        AuthorHandlePolicy.blocks(creatorID: record.creatorID, username: record.username,
                                  blockedIDs: authorBlocklist.blockedIDs, blockedHandles: authorBlocklist.blockedHandles)
    }
    private var unknownTagCount: Int { library.records.filter { $0.tagNames == nil }.count }
    private var storageFraction: Double { min(max(Double(library.diskBytes) / Double(max(1, library.capacity)), 0), 1) }
    private var storageOverview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("离线文件").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text("\(library.readyCount) / \(library.records.count) 项已下载").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(library.diskUsageKnown ? size(library.diskBytes) : "暂时无法统计").font(.system(size: 29, weight: .semibold, design: .rounded)).contentTransition(.numericText())
                Text("/ " + size(library.capacity)).font(.subheadline).foregroundStyle(.secondary)
            }
            if library.diskUsageKnown { ProgressView(value: storageFraction).tint(.blue).accessibilityLabel("离线空间占用") }
            VStack(alignment: .leading, spacing: 6) {
                Text(library.records.isEmpty && session.account == nil ? "登录后可同步并下载收藏" : library.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !authorBlocklist.entries.isEmpty {
                    Text("本机作者屏蔽只隐藏列表与播放，不删除离线文件或收藏关系。空间统计仍包含隐藏文件。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let date = library.lastScan {
                    Text("最近扫描 " + date.formatted(.dateTime.locale(Locale(identifier: "zh_Hans_CN")).month().day().hour().minute())).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 10)
    }
    private var browseControls: some View {
        Section("浏览本地作品") {
            Picker("媒体", selection: $kind) { ForEach(MediaKind.allCases) { Text($0.chineseTitle).tag($0) } }.pickerStyle(.segmented).padding(.vertical, 3)
            LabeledContent {
                Menu { Picker("作品状态", selection: $filter) { ForEach(OfflineFilter.allCases) { Text($0.rawValue).tag($0) } } } label: {
                    HStack(spacing: 5) { Text(filter.rawValue); Image(systemName: "chevron.down").font(.caption2) }
                }
            } label: { SettingsRowLabel("作品状态", "line.3.horizontal.decrease.circle") }
            LabeledContent {
                Menu { Picker("排列顺序", selection: $sort) { ForEach(OfflineSort.allCases) { Text($0.rawValue).tag($0) } } } label: {
                    HStack(spacing: 5) { Text(sort.rawValue); Image(systemName: "chevron.down").font(.caption2) }
                }
            } label: { SettingsRowLabel("排列顺序", "arrow.up.arrow.down") }
            if !blocklist.names.isEmpty {
                Text("屏蔽标签已启用；\(unknownTagCount) 项标签待核实，暂不展示。文件保留。").font(.caption).foregroundStyle(.secondary)
                if unknownTagCount > 0 { Button("联网更新收藏标签") { Task { await library.refreshTags(session: session) } }.disabled(library.busy || session.account == nil) }
            }
        }
    }
    private var downloadSection: some View {
        Section {
            if library.busy {
                if let value = library.progress { ProgressView(value: value) }
                else { ProgressView() }
                Button { library.pause() } label: { SettingsRowLabel("暂停同步", "pause.circle") }
            } else {
                Button { library.resumeAll(session: session) } label: { SettingsRowLabel("同步并下载收藏", "arrow.down.circle") }.disabled(!session.hasCollectionAccess)
            }
        } header: { Text("下载任务") } footer: { Text("同步在 App 前台进行，下载网络遵循设置。") }
    }
    private var recordsSection: some View {
        Section("本地作品 · \(visible.count)") {
            ForEach(visible, id: \.id) { (record: OfflineRecord) in recordRow(record) }
            if visible.isEmpty { Text("当前筛选下没有本地作品").foregroundStyle(.secondary) }
        }
    }
    private var managementSection: some View {
        Section {
            Button("删除所选本地副本（\(selected.count)）", role: .destructive) { confirmDelete = true }.disabled(selected.isEmpty)
            Button(selected.isEmpty ? "核对并清理已取消收藏" : "核对并清理所选项") { confirmClean = true }.disabled(library.busy || !session.hasCollectionAccess)
            Menu {
                Button("清理浏览缓存（保留离线文件）") { MediaCache.shared.clear() }
                Button("重新下载全部（含手动移除的副本）") { library.resumeAll(session: session, includeRemovedCopies: true) }.disabled(library.busy || !session.hasCollectionAccess)
                Button("清理全部离线收藏并关闭自动保存", role: .destructive) { confirmAll = true }
            } label: { SettingsRowLabel("更多空间操作", "ellipsis.circle") }
        } header: { Text("空间管理") } footer: { Text("删除本地副本不会修改 Civitai 收藏。手动移除后不会自动重新下载；可用“重新下载全部”恢复。空间满时暂停下载，不自动逐出已保存作品。") }
    }
    var body: some View {
        List(selection: $selected) {
            Section { storageOverview } footer: { Text("独立于浏览缓存保存；取消云端收藏会保留手机副本。") }
            downloadSection
            browseControls
            recordsSection
            managementSection
        }
        .navigationTitle("离线收藏与空间").navigationBarTitleDisplayMode(.inline).listStyle(.insetGrouped)
        .environment(\.editMode, $editMode)
        .environment(\.defaultMinListRowHeight, 52)
        .toolbar { Button(editMode.isEditing ? "完成" : "选择") {
            withAnimation {
                if editMode.isEditing { editMode = .inactive; selected = [] }
                else { editMode = .active }
            }
        } }
        .task(id: blocklist.names) { if !blocklist.names.isEmpty { await library.refreshTags(session: session) } }
        .onChange(of: kind) { _, _ in selected = [] }
        .onChange(of: filter) { _, _ in selected = [] }
        .onChange(of: visible.map(\.id)) { _, ids in selected.formIntersection(ids) }
        .onChange(of: authorBlocklist.entries) { _, _ in
            guard let focused, let current = viewerItems.first(where: { $0.id == focused }), authorBlocklist.blocks(current) else { return }
            if let next = visibleViewerItems.first { self.focused = next.id }
            else { viewerItem = nil; self.focused = nil }
        }
        .confirmationDialog("删除所选手机副本？云端收藏保留。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除 \(selected.count) 项本地副本", role: .destructive) { library.removeLocal(selected); selected = [] }
        }
        .confirmationDialog("联网核对，只清理已确认不在收藏夹的本地文件。", isPresented: $confirmClean, titleVisibility: .visible) {
            Button("核对并清理", role: .destructive) { library.cleanUnfavorited(session: session, ids: selected.isEmpty ? nil : selected); selected = [] }
        }
        .confirmationDialog("清理全部离线文件，同时关闭自动保存；浏览缓存和云端收藏保留。", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("清理全部离线收藏", role: .destructive) { library.clearAll(); selected = [] }
        }
        .fullScreenCover(item: $viewerItem, onDismiss: { creator = nil; viewerItems = [] }) { opening in
            offlineViewer(opening)
        }
    }
    private func offlineViewer(_ opening: MediaItem) -> some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()
                if !visibleViewerItems.isEmpty {
                    MediaDeck(items: visibleViewerItems, focused: $focused, initialID: opening.id, showsLoadMore: false, onAuthor: { creator = $0 }) {}
                } else {
                    ContentUnavailableView("作品被本机作者屏蔽", systemImage: "person.crop.circle.badge.xmark",
                                           description: Text("离线文件仍保留；取消作者屏蔽后可重新打开。"))
                        .foregroundStyle(.white)
                }
                Button { viewerItem = nil } label: { Image(systemName: "xmark").padding(15).background(.black.opacity(0.4), in: Circle()) }.padding(15).accessibilityLabel("关闭作品")
            }.tint(.white).toolbar(.hidden, for: .navigationBar)
                .onChange(of: focused) { _, id in if let id { library.opened(id) } }
                .navigationDestination(item: $creator) { CreatorView(creator: $0.creator, initialKind: $0.kind) }
        }.preferredColorScheme(creator == nil ? .dark : ordinaryScheme)
    }
    @ViewBuilder private func recordRow(_ record: OfflineRecord) -> some View {
        if editMode.isEditing {
            OfflineRecordRow(record: record, directory: library.directory, blurMature: session.account?.blurNsfw ?? true).tag(record.id)
        } else {
            Button(action: { openRecord(record) }) {
                OfflineRecordRow(record: record, directory: library.directory, blurMature: session.account?.blurNsfw ?? true)
            }.tag(record.id).accessibilityIdentifier("offline.item.\(record.id)")
            .contextMenu {
                Button("删除此本地副本", role: .destructive) { selected = Set([record.id]); confirmDelete = true }
            }
        }
    }
    private func openRecord(_ record: OfflineRecord) {
        guard record.fileState == .ready, !authorIsBlocked(record), let directory = library.directory else { return }
        let item = record.media(in: directory)
        viewerItems = playable; focused = item.id; library.opened(item.id); viewerItem = item
    }
    private func size(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: value)
    }
}

private struct OfflineRecordRow: View {
    let record: OfflineRecord
    let directory: URL?
    let blurMature: Bool
    private var title: String { (record.video ? "视频" : "图片") + " #" + String(record.id) }
    private var details: String { fileTitle + " · " + cloudTitle }
    var body: some View {
        HStack(spacing: 12) {
            thumbnail.frame(width: 68, height: 78).clipped().blur(radius: blurMature && ((record.browsingLevel ?? 1) & 28 != 0) ? 16 : 0).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.monospacedDigit()).foregroundStyle(.primary)
                Text("@" + (record.username ?? "作者")).font(.subheadline).lineLimit(1).foregroundStyle(.primary)
                Text(details).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(ByteCountFormatter.string(fromByteCount: record.bytes, countStyle: .file))
                    if let date = record.savedAt { Text(date.formatted(.dateTime.locale(Locale(identifier: "zh_Hans_CN")).year().month().day())) }
                }.font(.caption2).foregroundStyle(.secondary)
                if let date = record.lastOpenedAt { Text("最近打开 " + date.formatted(.dateTime.locale(Locale(identifier: "zh_Hans_CN")).month().day().hour().minute())).font(.caption2).foregroundStyle(.secondary) }
            }
        }.padding(.vertical, 4)
    }
    @ViewBuilder private var thumbnail: some View {
        if let directory, record.fileState == .ready {
            let url = directory.appendingPathComponent(record.video ? record.posterName : record.fileName)
            if FileManager.default.fileExists(atPath: url.path) { CachedImage(url: url) }
            else { placeholder }
        } else { placeholder }
    }
    private var placeholder: some View {
        Image(systemName: record.fileState == .failed ? "exclamationmark.arrow.circlepath" : (record.video ? "play.rectangle" : "photo"))
            .font(.title).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
    }
    private var fileTitle: String { switch record.fileState { case .ready: "已下载"; case .pending: "未下载"; case .failed: "下载失败" } }
    private var cloudTitle: String { switch record.cloudState { case .saved: "仍在收藏夹"; case .localOnly: "已取消收藏"; case .unknown: "待核对" } }
}
