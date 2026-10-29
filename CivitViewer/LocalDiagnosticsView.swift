import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct LocalDiagnosticsView: View {
    @State private var entries: [DiagnosticEntry] = []
    @State private var exportURL: URL?
    @State private var showingClear = false
    @State private var errorMessage: String?
    @State private var loading = true
    @State private var busy = false
    @State private var operationRevision = 0
    @State private var active = false

    var body: some View {
        List {
            Section {
                Text("仅保存在本机。记录公开作品或标签编号、查询范围、处理数量及系统错误码；不包含账号、搜索文字、请求地址或任意错误文本。最多保留 7 天、1,000 条。")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button("准备导出") { Task { await prepareExport() } }.disabled(busy)
                    if let exportURL {
                        ShareLink(item: exportURL) { Label("分享文件…", systemImage: "square.and.arrow.up") }
                    }
                    Spacer()
                    Button("清除", role: .destructive) { showingClear = true }.disabled(entries.isEmpty || busy)
                }
                if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.secondary) }
            }
            if loading { Section { ProgressView("读取本机记录…") } }
            Section("本机记录（最新在前）") {
                if entries.isEmpty && !loading { Text("暂无记录").foregroundStyle(.secondary) }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(entry.area.title).font(.subheadline.weight(.semibold))
                            Text(entry.code.title).font(.subheadline)
                            Spacer()
                            if let status = entry.httpStatus { Text("HTTP \(status)").font(.caption.monospacedDigit()) }
                        }
                        HStack(spacing: 10) {
                            Text(entry.timestamp.formatted(.dateTime.locale(Locale(identifier: "zh_Hans_CN")).month().day().hour().minute().second()))
                            Text("版本 \(entry.build)")
                            if let count = entry.count { Text(entry.code.isFrameReadyMeasurement ? "首帧 \(count) ms" : "数量 \(count)") }
                            if entry.suppressed > 0 { Text("合并 \(entry.suppressed) 条重复记录") }
                        }.font(.caption).foregroundStyle(.secondary)
                        if let playback = entry.playback {
                            Text(playback.summary).font(.caption.monospacedDigit()).textSelection(.enabled)
                        }
                        if let tagSearch = entry.tagSearch {
                            Text(tagSearch.summary).font(.caption.monospacedDigit()).textSelection(.enabled)
                        }
                    }.padding(.vertical, 3)
                }
            }
        }
        .navigationTitle("本机诊断记录")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await reload() }
        .onDisappear { leaveView() }
        .confirmationDialog("清除本机诊断记录？", isPresented: $showingClear, titleVisibility: .visible) {
            Button("清除记录", role: .destructive) { Task { await clear() } }.disabled(busy)
            Button("取消", role: .cancel) {}
        } message: { Text("只清除 Civit Viewer 自己的诊断日志文件。") }
    }

    @MainActor private func reload() async {
        active = true
        operationRevision += 1
        busy = false
        loading = true
        defer { loading = false }
        do { entries = try await LocalDiagnosticsStore.shared.entries(); errorMessage = nil }
        catch { errorMessage = "暂时无法读取本机记录。" }
    }

    @MainActor private func prepareExport() async {
        guard active, !busy else { return }
        busy = true
        operationRevision += 1
        let revision = operationRevision
        defer { if operationRevision == revision { busy = false } }
        do {
            let data = try await LocalDiagnosticsStore.shared.exportData()
            guard operationRevision == revision else { return }
            let destination = Self.exportURL
            let directory = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var directoryValues = URLResourceValues(); directoryValues.isExcludedFromBackup = true
            var mutableDirectory = directory; try mutableDirectory.setResourceValues(directoryValues)
            try data.write(to: destination, options: .atomic)
            var fileValues = URLResourceValues(); fileValues.isExcludedFromBackup = true
            var mutableFile = destination; try mutableFile.setResourceValues(fileValues)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
            #endif
            guard operationRevision == revision else {
                try? FileManager.default.removeItem(at: destination)
                return
            }
            exportURL = destination
            errorMessage = nil
        } catch { if active, operationRevision == revision { errorMessage = "暂时无法准备导出文件。" } }
    }

    @MainActor private func clear() async {
        guard active, !busy else { return }
        busy = true
        operationRevision += 1
        let revision = operationRevision
        exportURL = nil
        try? FileManager.default.removeItem(at: Self.exportURL)
        defer { if operationRevision == revision { busy = false } }
        do {
            try await LocalDiagnosticsStore.shared.clear()
            guard operationRevision == revision else { return }
            entries = []; errorMessage = nil
        } catch { if active, operationRevision == revision { errorMessage = "暂时无法清除本机记录。" } }
    }

    @MainActor private func leaveView() {
        operationRevision += 1
        active = false
        busy = false
        exportURL = nil
        try? FileManager.default.removeItem(at: Self.exportURL)
    }

    private static var exportURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CivitViewerDiagnostics", isDirectory: true)
            .appendingPathComponent("diagnostics.json")
    }
}
