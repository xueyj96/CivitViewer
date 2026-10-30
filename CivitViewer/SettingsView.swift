import SwiftUI

struct FilterView: View {
    @Binding var filter: FeedFilter
    var allowAll = true
    var context: FilterContext = .discovery
    var saveAsDefaultForFollowing: Bool? = nil
    var showsMediaSelector = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                if showsMediaSelector {
                    Section("默认媒体") {
                        Picker("默认媒体", selection: Binding(get: { filter.effectiveKind }, set: { filter = filter.selecting(kind: $0) })) { ForEach(allowAll ? MediaKind.allCases : [.image, .video]) { Text($0.title).tag($0) } }.pickerStyle(.segmented).accessibilityIdentifier("filter.media-kind")
                    }
                }
                Section("排序与范围") {
                    Picker("排序", selection: $filter.sort) {
                        ForEach(FeedSort.allCases) { Text($0.title).tag($0.rawValue) }
                    }.accessibilityIdentifier("filter.sort")
                    Picker("时间范围", selection: $filter.period) {
                        ForEach(FeedPeriod.allCases) { Text($0.title).tag($0.rawValue) }
                    }.accessibilityIdentifier("filter.period")
                }
                Section("内容范围") {
                    Picker("基础模型", selection: $filter.baseModel) {
                        Text("全部").tag(""); Text("SDXL").tag("SDXL 1.0"); Text("Flux.1 D").tag("Flux.1 D"); Text("Wan Video").tag("Wan Video")
                    }
                    Toggle("仅看 PG", isOn: $filter.onlyPG)
                    Text("关闭“仅看 PG”时，内容范围遵循 Civitai 账号和站点规则。").font(.caption).foregroundStyle(.secondary)
                }
                VideoDurationFilterSection(range: $filter.videoDurationRange)
                Button("重置筛选") { filter = filter.resetting(in: context) }
                Text("选择立即生效；关闭面板保留当前选择。").font(.caption).foregroundStyle(.secondary)
            }.navigationTitle("浏览筛选").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    AppToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.buttonStyle(AppActionButtonStyle()) }
                }
        }.ordinaryAppearance().environment(\.defaultMinListRowHeight, 52)
            .onChange(of: filter) { _, value in if let followed = saveAsDefaultForFollowing { value.saveDefault(followed: followed) } }
    }
}

struct VideoDurationFilterSection: View {
    @Binding var range: VideoDurationRange?
    var body: some View {
        Section {
            Toggle("筛选视频时长", isOn: Binding(get: { range != nil }, set: { enabled in
                range = enabled ? .init() : nil
            }))
            VideoDurationRangeControl(range: $range)
            Text("每档1秒，拖动时实时显示；点上方数值可逐秒微调。最短末端为“超过02:00”，最长末端为“不限”。")
                .font(.caption).foregroundStyle(.secondary)
            if range != nil {
                Text("仅匹配已知时长的视频；切换到图片或全部时清除时长限制。").font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text("视频时长") } footer: {
            Text("仅匹配已取得且时长已知的视频。未知暂不展示，可继续查找。关闭后不限制时长。")
        }
    }
}

struct SettingsRowLabel: View {
    let title: String
    let symbol: String
    init(_ title: String, _ symbol: String) { self.title = title; self.symbol = symbol }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 19, weight: .regular)).frame(width: 26, height: 26).accessibilityHidden(true)
            Text(title).fixedSize(horizontal: false, vertical: true)
        }.frame(minHeight: 34)
    }
}

private struct BlockedTagsView: View {
    @ObservedObject private var blocklist = TagBlocklist.shared
    @State private var name = ""
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                TextField("输入站点标签名", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit(add)
                Button(action: add) { SettingsRowLabel("添加屏蔽标签", "plus.circle") }.disabled(TagPolicy.normalize(name).isEmpty)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            } header: { Text("添加标签") } footer: { Text("名称忽略大小写及首尾空白，按站点返回的标签名称精确匹配，不自动扩充同义词。") }
            Section("已屏蔽 · \(blocklist.names.count)") {
                if blocklist.names.isEmpty { Text("尚未设置屏蔽标签").foregroundStyle(.secondary) }
                ForEach(blocklist.names.sorted(), id: \.self) { tag in
                    HStack {
                        SettingsRowLabel(tag, "tag.slash")
                        Spacer()
                        Button(role: .destructive) { blocklist.remove(tag) } label: { Image(systemName: "minus.circle").frame(width: 44, height: 44) }.accessibilityLabel("删除屏蔽标签 " + tag)
                    }
                }
            }
            Section("生效范围") {
                Text("仅保存在本机，应用于本客户端的推荐、关注、作品榜、作者作品、收藏及离线查看；不会更改 Civitai 账号设置或删除作品。")
                Text("开启屏蔽后，标签尚未取得的作品暂不展示，仍可继续翻页。离线旧文件需联网更新标签后展示。仅依赖站点返回标签，不识别画面，也不能保证站点标签完整。")
            }.font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("屏蔽标签").ordinaryAppearance().appNavigationBack().environment(\.defaultMinListRowHeight, 52)
    }
    private func add() {
        if blocklist.add(name) { name = ""; error = nil }
        else { error = "请使用 1—80 个字符，最多保存 100 个标签。" }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var session: SiteSession
    @ObservedObject private var cache = MediaCache.shared
    @ObservedObject private var offline = OfflineLibrary.shared
    @ObservedObject private var orientation = ViewingOrientationController.shared
    @AppStorage("offlineAutoSave") private var offlineAutoSave = true
    @AppStorage("offlineWifiOnly") private var offlineWifiOnly = true
    @AppStorage("offlineLimitGB") private var offlineLimitGB = 10
    @AppStorage("autoplay") private var autoplay = true
    @AppStorage("muted") private var muted = true
    @AppStorage("automaticVideoRepair") private var automaticVideoRepair = true
    @AppStorage("wifiVideoPrefetch") private var wifiVideoPrefetch = true
    @AppStorage("mediaPrefetchCount") private var mediaPrefetchCount = 6
    @AppStorage("mediaPrefetchConcurrency") private var mediaPrefetchConcurrency = 4
    @State private var showsGestureHelp = false
    @AppStorage("cacheLimitGB") private var cacheLimitGB = 5
    @AppStorage("deduplicateMedia") private var deduplicateMedia = true
    @AppStorage(AppTheme.appearanceKey) private var appearanceRaw = AppAppearance.system.rawValue
    @State private var defaultDiscovery = FeedFilter.saved()
    @State private var defaultFollowing = FeedFilter.saved(followed: true)
    @State private var editDefault: Int?
    private var appearanceSelection: Binding<AppAppearance> {
        Binding(get: { AppAppearance(rawValue: appearanceRaw) ?? .system }, set: { appearanceRaw = $0.rawValue })
    }
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return "\(version) (\(build))"
    }
    private func storageSize(_ bytes: Int64) -> String {
        if bytes == 0 { return "0 KB" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }
    var body: some View {
        Form {
            Section("Civitai 账号") {
                if let account = session.account {
                    LabeledContent { Text(account.username) } label: { SettingsRowLabel("当前账号", "person.crop.circle") }
                    Button { Task { await session.refreshAccount() } } label: { SettingsRowLabel("刷新账号与关注", "arrow.clockwise") }
                    NavigationLink { AccountPreferencesView() } label: { SettingsRowLabel("账号内容偏好", "gearshape") }
                    NavigationLink { FollowingView() } label: { SettingsRowLabel("关注的作者", "person.2") }
                    NavigationLink { CollectionsView() } label: { SettingsRowLabel("我的收藏", "bookmark") }
                    NavigationLink { OfflineStorageView().appNavigationBack() } label: { SettingsRowLabel("离线收藏与空间管理", "internaldrive") }
                    Button(role: .destructive) { Task { await session.clearLocalLogin() } } label: { SettingsRowLabel("退出此客户端", "rectangle.portrait.and.arrow.right") }
                } else {
                    Button { session.openLogin() } label: { SettingsRowLabel("登录 Civitai", "person.crop.circle") }
                    NavigationLink { OfflineStorageView().appNavigationBack() } label: { SettingsRowLabel("离线收藏与空间管理", "internaldrive") }
                }
                LabeledContent { Text("civitai.red") } label: { SettingsRowLabel("连接站点", "globe") }
            }
            Section("外观") {
                Picker(selection: appearanceSelection) {
                    ForEach(AppAppearance.allCases) { appearance in Text(appearance.title).tag(appearance) }
                } label: { SettingsRowLabel("显示模式", "circle.lefthalf.filled") }
                    .pickerStyle(.menu).accessibilityIdentifier("settings-appearance-picker")
                    .accessibilityValue(appearanceSelection.wrappedValue.title)
            }
            Section("播放") {
                Toggle(isOn: $autoplay) { SettingsRowLabel("自动播放视频", "play.circle") }
                Toggle(isOn: $muted) { SettingsRowLabel("视频默认静音", "speaker.slash") }
                Toggle(isOn: $automaticVideoRepair) { SettingsRowLabel("自动修复不兼容视频", "wand.and.stars") }
                Text("仅修复当前打开的视频；先无损转封装，必要时转换为 H.264/AAC。划走或进入后台会停止转换，完成的修复文件可复用。").font(.caption).foregroundStyle(.secondary)
                Toggle(isOn: Binding(get: { orientation.automatic }, set: { orientation.setAutomatic($0) })) { SettingsRowLabel("自动旋转", "rotate.right") }
                Text("默认关闭；观看时仍可手动切换横竖屏。开启后跟随系统允许的方向。").font(.caption).foregroundStyle(.secondary)
            }
            Section("浏览记录") {
                NavigationLink { BrowsingHistoryView().appNavigationBack() } label: { SettingsRowLabel("最近浏览与接着看", "clock.arrow.circlepath") }
            }
            Section("诊断") {
                NavigationLink { LocalDiagnosticsView().appNavigationBack() } label: { SettingsRowLabel("本机错误与诊断记录", "stethoscope") }
            }
            Section("默认浏览设置") {
                Button { editDefault = 0 } label: { SettingsRowLabel("推荐时间线默认筛选", "slider.horizontal.3") }
                Button { editDefault = 1 } label: { SettingsRowLabel("关注时间线默认筛选", "person.2") }
                NavigationLink { BlockedTagsView() } label: { SettingsRowLabel("屏蔽标签", "tag.slash") }
                NavigationLink { AuthorBlocklistView().appNavigationBack() } label: { SettingsRowLabel("屏蔽的作者", "person.crop.circle.badge.xmark") }
                Text("作者屏蔽仅在本机生效。不会更改站点设置或删除收藏、浏览记录和离线作品。")
                    .font(.caption).foregroundStyle(.secondary)
                NavigationLink { LocalTagLibraryView().appNavigationBack() } label: { SettingsRowLabel("本地标签库与同步", "externaldrive") }
                Toggle(isOn: $deduplicateMedia) { SettingsRowLabel("合并相同媒体", "rectangle.on.rectangle.slash") }
                Text("搜索、时间线、作者和收藏列表统一去重。关闭后可查看同媒体的不同作品记录；收藏操作仍针对当前作品，不合并云端关系。").font(.caption).foregroundStyle(.secondary)
                Text("默认筛选用于下次打开客户端；当前两条时间线分别保留自己的筛选和浏览位置。").font(.caption).foregroundStyle(.secondary)
            }
            Section("时间线缓存") {
                Toggle(isOn: $wifiVideoPrefetch) { SettingsRowLabel("仅在 Wi-Fi 下预取视频", "wifi") }
                Picker(selection: $mediaPrefetchCount) {
                    ForEach([3, 6, 10], id: \.self) { Text("后续 \($0) 条").tag($0) }
                } label: { SettingsRowLabel("预加载作品", "arrow.down.circle") }
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        SettingsRowLabel("预载并发", "arrow.down.forward.and.arrow.up.backward")
                        Spacer()
                        Text("\(MediaPrefetchConcurrency.validated(mediaPrefetchConcurrency)) 路")
                            .foregroundStyle(.blue).monospacedDigit()
                            .accessibilityIdentifier("settings.prefetch-concurrency.value")
                    }
                    Slider(value: Binding(get: {
                        Double(MediaPrefetchConcurrency.steps.firstIndex(of: MediaPrefetchConcurrency.validated(mediaPrefetchConcurrency)) ?? 1)
                    }, set: { value in
                        let index = min(max(Int(value.rounded()), 0), MediaPrefetchConcurrency.steps.count - 1)
                        mediaPrefetchConcurrency = MediaPrefetchConcurrency.steps[index]
                    }), in: 0...Double(MediaPrefetchConcurrency.steps.count - 1), step: 1)
                        .accessibilityLabel("预载并发")
                        .accessibilityValue("\(MediaPrefetchConcurrency.validated(mediaPrefetchConcurrency)) 路")
                        .accessibilityIdentifier("settings.prefetch-concurrency")
                    HStack {
                        ForEach(Array(MediaPrefetchConcurrency.steps.enumerated()), id: \.offset) { index, value in
                            if index > 0 { Spacer() }
                            Text("\(value)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }.accessibilityHidden(true)
                    Text("图片与视频共用下载路数，与后续作品条数独立。当前播放优先，缓冲时预载让路，随后自动继续。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 5)
                if let status = cache.preloadStatus {
                    LabeledContent("预加载状态", value: status.summary)
                    if !status.detail.isEmpty { Text(status.detail).font(.caption).foregroundStyle(.secondary) }
                }
                Text("连续准备后续图片和视频，减少滑动时的等待。低数据模式或计费热点会暂停仅 Wi-Fi 的视频预载。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("单条视频最多预取 512 MiB，并受当前缓存与可用空间预算限制。")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent { Text(cache.diskUsageKnown ? storageSize(cache.diskBytes) : "暂时无法统计") } label: { SettingsRowLabel("媒体缓存", "internaldrive") }
                    .accessibilityIdentifier("settings.media-cache-size")
                Picker(selection: $cacheLimitGB) {
                    ForEach([1, 5, 10, 20], id: \.self) { Text("\($0) GB").tag($0) }
                } label: { SettingsRowLabel("磁盘缓存上限", "externaldrive") }
                LabeledContent { Text("\(cache.cacheHits) 次") } label: { SettingsRowLabel("本次缓存复用", "arrow.triangle.2.circlepath") }
                Text("包含原媒体与兼容修复文件，按最近使用时间逐出，保护正在播放和接下来要看的文件。可用空间不足 1 GB 时停止预取并提前清理。上限不会预先占用空间。").font(.caption).foregroundStyle(.secondary)
                Button { cache.clear() } label: { SettingsRowLabel("清理媒体缓存", "trash") }
            }
            Section("离线收藏 · 独立存储") {
                Toggle(isOn: $offlineAutoSave) { SettingsRowLabel("自动保存全部收藏", "arrow.down.circle") }
                Toggle(isOn: $offlineWifiOnly) { SettingsRowLabel("仅在 Wi-Fi 下下载收藏", "wifi") }
                LabeledContent { Text(offline.diskUsageKnown ? storageSize(offline.diskBytes) : "暂时无法统计") } label: { SettingsRowLabel("离线文件", "internaldrive") }
                LabeledContent { Text("\(offline.readyCount) 项") } label: { SettingsRowLabel("已下载", "checkmark.circle") }
                Picker(selection: $offlineLimitGB) {
                    ForEach([1,5,10,20,50], id: \.self) { Text("\($0) GB").tag($0) }
                } label: { SettingsRowLabel("当前账号离线上限", "externaldrive") }
                Text(offline.status).font(.caption).foregroundStyle(.secondary)
                Text("包含历史收藏；跨收藏夹去重。与浏览缓存独立，空间满时暂停下载。取消云端收藏保留本地副本，可在空间管理中按大小、时间和收藏状态清理。").font(.caption).foregroundStyle(.secondary)
            }
            Section("观看帮助") {
                DisclosureGroup(isExpanded: $showsGestureHelp) {
                    LabeledContent("上下划", value: "上一条／下一条")
                    LabeledContent("单击视频", value: "暂停／继续")
                    LabeledContent("双击作品", value: "进入作者主页")
                    LabeledContent("边缘左右划", value: "图片／全部／视频")
                    LabeledContent("视频中央左右划", value: "快退／快进")
                    LabeledContent("边缘长按", value: "临时 2×，松手恢复")
                    LabeledContent("中央长按", value: "清屏／恢复")
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("中央长按，清屏／恢复")
                        .accessibilityIdentifier("settings.gesture.central-hold")
                } label: { SettingsRowLabel("手势帮助", "hand.tap") }
                .accessibilityIdentifier("settings.gesture-help")
            }
            Section("关于") {
                Text("Civit Viewer · 个人使用的第三方客户端").font(.caption)
                LabeledContent { Text(appVersion) } label: { SettingsRowLabel("版本", "info.circle") }
                Text("Google 登录由系统浏览器中的 Civitai 官网处理。授权凭据仅保存在本机 Keychain。").font(.caption).foregroundStyle(.secondary)
                NavigationLink { MediaRepairLicenseView().appNavigationBack() } label: { SettingsRowLabel("开源组件", "curlybraces") }
            }
        }.navigationTitle("账号与设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .ordinaryAppearance().environment(\.defaultMinListRowHeight, 52).onAppear { cache.trim() }
            .onChange(of: cacheLimitGB) { _, _ in cache.trim() }
            .onChange(of: offlineAutoSave) { _, enabled in
                if enabled { offline.resumeAll(session: session, includeRemovedCopies: true) }
                else { offline.pause(reason: "自动保存已关闭") }
            }
            .onChange(of: offlineWifiOnly) { _, _ in offline.pause(); if offlineAutoSave { offline.requestSync(session: session) } }
            .onChange(of: offlineLimitGB) { _, _ in if offlineAutoSave { offline.requestSync(session: session) } }
            .sheet(isPresented: Binding(get: { editDefault != nil }, set: { if !$0 { editDefault = nil } })) {
                if editDefault == 1 { FilterView(filter: $defaultFollowing, context: .following, saveAsDefaultForFollowing: true, showsMediaSelector: true) }
                else { FilterView(filter: $defaultDiscovery, saveAsDefaultForFollowing: false, showsMediaSelector: true) }
            }
    }
}

struct AccountPreferencesView: View {
    @EnvironmentObject private var session: SiteSession
    @State private var level = 1
    @State private var blur = true
    @State private var saving = false
    private let levels: [(Int, String)] = [(1,"PG"),(2,"PG-13"),(4,"R"),(8,"X"),(16,"XXX")]
    var body: some View {
        Form {
            if session.account?.browsingLevel != nil {
                Section("账号浏览范围") {
                    ForEach(levels, id: \.0) { bit, title in
                        Toggle(title, isOn: Binding(get: { level & bit != 0 }, set: { enabled in if enabled { level |= bit } else { level &= ~bit } }))
                    }
                }
                if session.account?.blurNsfw != nil { Section { Toggle("模糊成熟内容", isOn: $blur) } }
                Section {
                    Button(saving ? "正在保存并核对…" : "保存到 Civitai") {
                        saving = true
                        Task { _ = await session.saveBrowsingPreferences(level: level, blur: session.account?.blurNsfw == nil ? nil : blur); saving = false }
                    }.disabled(saving || level == 0)
                    Text("使用站点分级；最终可见范围以 Civitai 对当前账号的规则为准。保存后会重新读取服务器值。").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("站点暂未返回账号浏览偏好，请先刷新账号状态。")
                Button("刷新账号") { Task { await session.refreshAccount() } }
            }
        }.navigationTitle("账号内容偏好").ordinaryAppearance().appNavigationBack().environment(\.defaultMinListRowHeight, 52).onAppear {
            level = session.account?.browsingLevel ?? 1; blur = session.account?.blurNsfw ?? true
        }
    }
}
