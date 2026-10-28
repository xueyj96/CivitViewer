import SwiftUI

struct LocalTagLibraryView: View {
    @EnvironmentObject private var session: SiteSession
    @ObservedObject private var library = LocalTagLibrary.shared
    @AppStorage("tagLibraryAuto") private var automatic = true
    @AppStorage("tagLibraryWiFi") private var wifiOnly = true
    @State private var confirmReset = false
    var body: some View {
        Form {
            Section {
                LabeledContent("可浏览标签", value: "\(library.stats.visible) 个")
                LabeledContent("已存元数据", value: "\(library.stats.stored) 项")
                LabeledContent("本轮字母／数字遍历", value: "\(library.stats.completedPrefixes) / 36")
                LabeledContent("独立占用", value: ByteCountFormatter.string(fromByteCount: library.stats.bytes, countStyle: .file) + " / 128 MiB")
            } footer: { Text("按站点和当前账号隔离保存标签元数据，与浏览缓存及离线收藏分开。只统计本地已收录数据，不代表全站总量。") }
            Section {
                Toggle("自动分批同步", isOn: $automatic)
                Toggle("仅在 Wi-Fi 下同步", isOn: $wifiOnly)
                HStack { if library.busy { ProgressView() }; Text(library.status).font(.subheadline) }
                if let date = library.stats.lastSuccessfulSync { LabeledContent("上次写入") { Text(date, style: .relative) } }
                if let error = library.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                if library.busy { Button("暂停同步") { library.pause(userInitiated: true) } }
                else { Button("同步下一批／重试") { library.requestSync(source: session, manual: true) } }
            } header: { Text("同步") } footer: { Text("初始按 A–Z 和数字分批读取，其他字符可在标签搜索中补充。每批最多 8 页，单个请求完成后保存断点；回到前台后继续。完成的前缀每天轮换复查，只合并变化，不因单次缺失自动删标签。") }
            Section {
                Button("清空当前标签库", role: .destructive) { confirmReset = true }
            } footer: { Text("清空只影响可重新同步的标签索引，不影响已选搜索条件、屏蔽规则、收藏或媒体文件。") }
        }.navigationTitle("本地标签库").navigationBarTitleDisplayMode(.inline)
            .onChange(of: automatic) { _, value in if !value { library.pause(reason: "自动同步已关闭") } }
            .onChange(of: wifiOnly) { _, _ in library.pause(reason: "同步网络设置已更新") }
            .confirmationDialog("清空当前账号的标签库？", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("清空标签索引", role: .destructive) { Task { await library.reset(ownerID: session.tagLibraryOwnerID) } }
            } message: { Text("之后可以重新同步。收藏、屏蔽规则和媒体文件保持原样。") }
    }
}
