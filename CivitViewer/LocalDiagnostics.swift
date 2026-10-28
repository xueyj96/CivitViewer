import Foundation

enum LocalDiagnosticsError: Error { case exportTooLarge }

enum DiagnosticArea: String, Codable, CaseIterable, Identifiable {
    case search, thumbnail, playback, cache, restore, history, lifecycle
    var id: Self { self }
    var title: String {
        switch self {
        case .search: "搜索"
        case .thumbnail: "缩略图"
        case .playback: "播放"
        case .cache: "缓存"
        case .restore: "恢复"
        case .history: "历史记录"
        case .lifecycle: "应用状态"
        }
    }
}

enum DiagnosticCode: String, Codable, CaseIterable, Identifiable {
    case network, http, decode, limit, queueFull, storage, invalidResponse
    case contextChanged, playbackFailed, seekFailed, loadFailed
    case appStarted, foreground, background, compatibilityPlaying
    case repairStarted, repairCompleted, repairedVideoPlaying
    case posterLoaded, posterFailed, posterCaptured
    case posterOpened, posterStarted, posterCancelled, posterCaptureStarted, posterDeferred
    var id: Self { self }
    var title: String {
        switch self {
        case .network: "网络请求失败"
        case .http: "HTTP 状态异常"
        case .decode: "响应解析失败"
        case .limit: "处理数量达到上限"
        case .queueFull: "任务队列已满"
        case .storage: "本地存储失败"
        case .invalidResponse: "响应内容无效"
        case .contextChanged: "账号或页面上下文变化"
        case .playbackFailed: "播放失败"
        case .seekFailed: "定位播放位置失败"
        case .loadFailed: "加载失败"
        case .appStarted: "应用启动"
        case .foreground: "应用进入前台"
        case .background: "应用进入后台"
        case .compatibilityPlaying: "兼容播放已开始"
        case .repairStarted: "本机视频修复开始"
        case .repairCompleted: "本机视频修复完成"
        case .repairedVideoPlaying: "修复后原生播放已推进"
        case .posterLoaded: "封面已取得"
        case .posterFailed: "封面加载失败"
        case .posterCaptured: "播放画面已保存为封面"
        case .posterOpened: "打开作品预览"
        case .posterStarted: "封面读取开始"
        case .posterCancelled: "封面读取已取消"
        case .posterCaptureStarted: "播放画面提取开始"
        case .posterDeferred: "等待提取封面"
        }
    }
}

struct DiagnosticEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let timestamp: Date
    let processSession: UUID
    let build: Int
    let area: DiagnosticArea
    let code: DiagnosticCode
    let httpStatus: Int?
    let count: Int?
    let suppressed: Int
    let playback: PlaybackFailureDiagnostic?
}

actor LocalDiagnosticsStore {
    private static let retention: TimeInterval = 7 * 24 * 60 * 60
    private static let segmentLimit = 256 * 1024
    private static let segmentEventLimit = 250
    private static let segmentCount = 4
    private static let maximumEvents = 1_000
    private static let maximumExportBytes = 1_100_000
    private static let processSessionID = UUID()

    private struct RateKey: Hashable {
        let area: DiagnosticArea
        let code: DiagnosticCode
        let status: Int?
        let playback: PlaybackFailureDiagnostic?
    }
    private struct Export: Codable {
        let schemaVersion: Int
        let entries: [DiagnosticEntry]
    }

    private let fileURL: URL
    private let build: Int
    private let now: @Sendable () -> Date
    private let fileManager = FileManager.default
    private var loaded = false
    private var retained: [DiagnosticEntry] = []
    private var perKeyLastWrite: [RateKey: Date] = [:]
    private var globalWrites: [Date] = []
    private var suppressedCount = 0
    private var currentSegmentBytes = 0
    private var currentSegmentEvents = 0
    private var needsRetentionCompaction = false

    init(fileURL: URL, build: Int, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.build = max(0, build)
        self.now = now
    }

    static let shared = LocalDiagnosticsStore(fileURL: defaultFileURL, build: Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0)

    nonisolated func note(area: DiagnosticArea, code: DiagnosticCode, httpStatus: Int? = nil, count: Int? = nil, playback: PlaybackFailureDiagnostic? = nil) {
        Task { await self.record(area: area, code: code, httpStatus: httpStatus, count: count, playback: playback) }
    }

    private static var defaultFileURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("CivitViewer", isDirectory: true)
            .appendingPathComponent("LocalDiagnostics", isDirectory: true)
            .appendingPathComponent("diagnostics-0.jsonl")
    }

    func record(area: DiagnosticArea, code: DiagnosticCode, httpStatus: Int? = nil, count: Int? = nil, playback: PlaybackFailureDiagnostic? = nil) async {
        do { try ensureLoaded() } catch { return }
        let timestamp = now()
        pruneRateState(at: timestamp)
        let safeStatus = httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }
        let allowsContext = area == .playback ||
            (area == .thumbnail && [.posterLoaded, .posterFailed, .posterCaptured, .posterOpened,
                                   .posterStarted, .posterCancelled, .posterCaptureStarted, .posterDeferred].contains(code))
        let safePlayback = allowsContext && playback?.isBounded == true ? playback : nil
        let rateKey = RateKey(area: area, code: code, status: safeStatus, playback: safePlayback)
        if let previous = perKeyLastWrite[rateKey], timestamp.timeIntervalSince(previous) < 10 {
            suppressedCount = min(1_000_000, suppressedCount + 1)
            return
        }
        if globalWrites.count >= 30 {
            suppressedCount = min(1_000_000, suppressedCount + 1)
            return
        }
        let entry = DiagnosticEntry(id: UUID(), timestamp: timestamp, processSession: Self.processSessionID,
                                    build: build, area: area, code: code, httpStatus: safeStatus,
                                    count: count.map { min(1_000_000_000, max(0, $0)) }, suppressed: suppressedCount, playback: safePlayback)
        let previouslySuppressed = suppressedCount
        suppressedCount = 0
        do {
            try append(entry)
            retained.append(entry)
            retained = Array(retained.suffix(Self.maximumEvents))
            perKeyLastWrite[rateKey] = timestamp
            globalWrites.append(timestamp)
            if let oldest = retained.first, timestamp.timeIntervalSince(oldest.timestamp) > Self.retention {
                retained = retained.filter { timestamp.timeIntervalSince($0.timestamp) <= Self.retention }
                try rewriteRetained()
            }
        } catch {
            // Diagnostics are deliberately business-safe and never recursively log their own failure.
            suppressedCount = min(1_000_000, previouslySuppressed + 1)
        }
    }

    func entries() async throws -> [DiagnosticEntry] {
        try ensureLoaded()
        let timestamp = now()
        let fresh = retained.filter { timestamp.timeIntervalSince($0.timestamp) <= Self.retention }
        if fresh.count != retained.count {
            retained = fresh
            try rewriteRetained()
        }
        return retained.sorted { $0.timestamp > $1.timestamp }
    }

    func exportData() async throws -> Data {
        let payload = Export(schemaVersion: 1, entries: try await entries())
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        guard data.count <= Self.maximumExportBytes else { throw LocalDiagnosticsError.exportTooLarge }
        return data
    }

    func clear() async throws {
        try ensureLoaded()
        for index in 0..<Self.segmentCount {
            let url = segmentURL(index)
            try removeOwnedSegmentIfSafe(url)
        }
        retained = []; perKeyLastWrite = [:]; globalWrites = []; suppressedCount = 0
        currentSegmentBytes = 0; currentSegmentEvents = 0; needsRetentionCompaction = false
    }

    private func ensureLoaded() throws {
        guard !loaded else { return }
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var directoryValues = URLResourceValues(); directoryValues.isExcludedFromBackup = true
        var mutableDirectory = directory; try mutableDirectory.setResourceValues(directoryValues)
        #if os(iOS)
        try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
        var entries: [DiagnosticEntry] = []
        for index in stride(from: Self.segmentCount - 1, through: 0, by: -1) {
            let url = segmentURL(index)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard let fileSize = (attributes[.size] as? NSNumber)?.int64Value, fileSize >= 0,
                  attributes[.type] as? FileAttributeType == .typeRegular else {
                needsRetentionCompaction = true
                continue
            }
            let readCount = Int(min(Int64(Self.segmentLimit), fileSize))
            let handle = try FileHandle(forReadingFrom: url)
            let data: Data
            do { data = try handle.read(upToCount: readCount) ?? Data(); try handle.close() }
            catch { try? handle.close(); throw error }
            if fileSize > Int64(Self.segmentLimit) { needsRetentionCompaction = true }
            if index == 0 {
                currentSegmentBytes = fileSize > Int64(Self.segmentLimit) ? Self.segmentLimit : data.count
                currentSegmentEvents = data.split(separator: 0x0A).count
                if fileSize > Int64(Self.segmentLimit) || (data.last != nil && data.last != 0x0A) {
                    currentSegmentEvents = Self.segmentEventLimit
                }
            }
            let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            for line in lines {
                guard let entry = try? decodeEntry(Data(line)) else { continue }
                entries.append(entry)
            }
        }
        let timestamp = now()
        retained = Array(entries.filter { timestamp.timeIntervalSince($0.timestamp) <= Self.retention }.suffix(Self.maximumEvents))
        needsRetentionCompaction = needsRetentionCompaction || retained.count != entries.count
        loaded = true
        if needsRetentionCompaction { try rewriteRetained() }
    }

    private func decodeEntry(_ data: Data) throws -> DiagnosticEntry {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(DiagnosticEntry.self, from: data)
        guard entry.playback?.isBounded != false else { throw CocoaError(.coderReadCorrupt) }
        return entry
    }

    private func append(_ entry: DiagnosticEntry) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(entry); line.append(0x0A)
        if currentSegmentEvents >= Self.segmentEventLimit || currentSegmentBytes + line.count > Self.segmentLimit {
            try rotateSegments()
            currentSegmentBytes = 0; currentSegmentEvents = 0
        }
        let target = segmentURL(0)
        if !fileManager.fileExists(atPath: target.path) {
            try line.write(to: target, options: [.atomic])
            try applyFileAttributes(target)
        } else {
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: line)
        }
        currentSegmentBytes += line.count; currentSegmentEvents += 1
    }

    private func rotateSegments() throws {
        for index in stride(from: Self.segmentCount - 1, through: 0, by: -1) {
            let source = segmentURL(index)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            guard try isSafeOwnedSegment(source) else { throw CocoaError(.fileWriteNoPermission) }
            if index == Self.segmentCount - 1 { try fileManager.removeItem(at: source) }
            else {
                let destination = segmentURL(index + 1)
                try removeOwnedSegmentIfSafe(destination)
                try fileManager.moveItem(at: source, to: destination)
            }
        }
    }

    private func rewriteRetained() throws {
        for index in 0..<Self.segmentCount {
            let url = segmentURL(index)
            try removeOwnedSegmentIfSafe(url)
        }
        currentSegmentBytes = 0; currentSegmentEvents = 0
        let values = retained
        for entry in values { try append(entry) }
        needsRetentionCompaction = false
    }

    private func pruneRateState(at timestamp: Date) {
        perKeyLastWrite = perKeyLastWrite.filter { timestamp.timeIntervalSince($0.value) < 10 }
        globalWrites.removeAll { timestamp.timeIntervalSince($0) >= 60 }
    }

    private func segmentURL(_ index: Int) -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("diagnostics-\(index).jsonl")
    }

    private func isSafeOwnedSegment(_ url: URL) throws -> Bool {
        guard let type = try fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType else { return false }
        return type == .typeRegular || type == .typeSymbolicLink
    }

    private func removeOwnedSegmentIfSafe(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path), try isSafeOwnedSegment(url) else { return }
        try fileManager.removeItem(at: url)
    }

    private func applyFileAttributes(_ url: URL) throws {
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var mutableURL = url; try mutableURL.setResourceValues(values)
        #if os(iOS)
        try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}
