import Foundation
import Combine
import CryptoKit

/// A captured owner and revision. Late player/exposure callbacks cannot recreate
/// entries after clearing history, pausing recording, or changing accounts.
struct HistoryContext: Equatable {
    let ownerKey: String
    let generation: Int
}

@MainActor final class BrowsingHistory: ObservableObject {
    static let shared: BrowsingHistory = {
        #if DEBUG && targetEnvironment(simulator)
        if ViewportAuditQA.enabled { return BrowsingHistory(rootURL: ViewportAuditQA.historyRoot) }
        if ResumePromptQA.enabled {
            return BrowsingHistory(rootURL: ResumePromptQA.rootURL)
        }
        if ProcessInfo.processInfo.arguments.contains("--qa-history-screen") {
            return BrowsingHistory(rootURL: HistoryQA.rootURL)
        }
        #endif
        return BrowsingHistory(diagnostics: .shared)
    }()
    @Published private(set) var records: [HistoryRecord] = []
    @Published private(set) var checkpoints: [TimelineCheckpoint] = []
    @Published private(set) var recordingEnabled = true
    @Published private(set) var ready = false
    @Published private(set) var generation = 0
    @Published private(set) var error: String?
    private var database: BrowsingHistoryDatabase?
    private var ownerKey: String?
    private var identity: String?
    private var tail: Task<Void, Never>?
    private var progressWrittenAt: [Int: Date] = [:]
    // One offer baseline per account for this app process. Current viewing
    // writes checkpoints continuously; those writes are not a new past visit.
    private var resumeBaselines: [String: [HistoryLane: TimelineCheckpoint]] = [:]
    private let rootURL: URL
    private let diagnostics: LocalDiagnosticsStore?

    init(rootURL: URL? = nil, diagnostics: LocalDiagnosticsStore? = nil) {
        self.rootURL = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CivitHistory", isDirectory: true)
        self.diagnostics = diagnostics
    }
    static func key(_ id: Int?) -> String {
        SHA256.hash(data: Data((id.map { "account:\($0)" } ?? "anonymous").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func context(ownerID: Int?) -> HistoryContext? {
        guard ready, ownerKey == Self.key(ownerID), let ownerKey else { return nil }
        return HistoryContext(ownerKey: ownerKey, generation: generation)
    }
    func accepts(_ context: HistoryContext) -> Bool {
        ready && ownerKey == context.ownerKey && generation == context.generation
    }
    func bind(ownerID: Int?, identity: String) async {
        guard !Task.isCancelled else { return }
        let key = Self.key(ownerID)
        guard self.identity != identity || database == nil else { return }
        generation += 1; let revision = generation
        self.identity = identity; ownerKey = key; ready = false; error = nil
        records = []; checkpoints = []; recordingEnabled = true; progressWrittenAt = [:]
        // Invalidating UI callbacks cannot cancel a disk write already inside
        // the old actor. Drain its queue before reopening the same owner file.
        let previous = tail; database = nil
        await previous?.value
        guard revision == generation, ownerKey == key, !Task.isCancelled else { return }
        let db = BrowsingHistoryDatabase(fileURL: rootURL.appendingPathComponent(key).appendingPathComponent("history.json"), ownerKey: key)
        database = db; tail = nil
        do {
            let archive = try await db.load()
            guard revision == generation, ownerKey == key else { return }
            if resumeBaselines[key] == nil {
                resumeBaselines[key] = Dictionary(archive.checkpoints.map { ($0.lane, $0) }, uniquingKeysWith: { _, latest in latest })
            }
            apply(archive); ready = true
        } catch {
            guard revision == generation else { return }
            self.error = "浏览历史暂时无法读取。已有文件保留，可稍后重试。"
            diagnostics?.note(area: .history, code: .storage)
        }
    }
    func retry(ownerID: Int?, identity: String) async {
        database = nil
        await bind(ownerID: ownerID, identity: identity)
    }
    func record(_ item: MediaItem, context: HistoryContext, checkpoint: TimelineCheckpoint? = nil) {
        guard accepts(context), recordingEnabled else { return }
        let record = HistoryRecord(id: item.id, kind: item.isVideo ? .video : .image, authorName: item.username,
                                   creatorID: item.creatorID, viewedAt: Date(), positionSeconds: nil, durationSeconds: nil)
        enqueue(context) { db in
            let archive = try await db.record(record)
            if let checkpoint { return try await db.checkpoint(checkpoint) }
            return archive
        }
    }
    func progress(id: Int, position: Double, duration: Double, flush: Bool, context: HistoryContext) {
        guard accepts(context), recordingEnabled, position.isFinite, duration.isFinite, duration > 0, position >= 0 else { return }
        let now = Date()
        guard flush || now.timeIntervalSince(progressWrittenAt[id] ?? .distantPast) >= 5 else { return }
        progressWrittenAt[id] = now
        enqueue(context) { try await $0.progress(id: id, position: position, duration: duration, now: now) }
    }
    func checkpoint(_ value: TimelineCheckpoint, context: HistoryContext) {
        guard accepts(context), recordingEnabled else { return }
        enqueue(context) { try await $0.checkpoint(value) }
    }
    func checkpoint(for lane: HistoryLane) -> TimelineCheckpoint? { checkpoints.first { $0.lane == lane } }
    func resumeOffer(for lane: HistoryLane, context: HistoryContext) -> TimelineCheckpoint? {
        guard accepts(context) else { return nil }
        return resumeBaselines[context.ownerKey]?[lane]
    }
    func resumePosition(for id: Int) -> Double? {
        guard let record = records.first(where: { $0.id == id }) else { return nil }
        return PlaybackResumePolicy.position(position: record.positionSeconds, duration: record.durationSeconds)
    }
    func remove(ids: Set<Int>, context: HistoryContext) {
        guard accepts(context) else { return }
        if let offers = resumeBaselines[context.ownerKey] {
            resumeBaselines[context.ownerKey] = offers.compactMapValues { checkpoint in
                guard !ids.contains(checkpoint.focusedID) else { return nil }
                var retained = checkpoint; retained.ids.removeAll { ids.contains($0) }
                return retained.ids.isEmpty ? nil : retained
            }
        }
        // Invalidate pending exposure and progress callbacks before the write.
        generation += 1; progressWrittenAt = [:]
        let current = HistoryContext(ownerKey: context.ownerKey, generation: generation)
        enqueue(current) { try await $0.remove(ids: ids) }
    }
    func clear(context: HistoryContext) {
        guard accepts(context) else { return }
        resumeBaselines[context.ownerKey] = [:]
        generation += 1; progressWrittenAt = [:]
        let current = HistoryContext(ownerKey: context.ownerKey, generation: generation)
        enqueue(current) { try await $0.clear() }
    }
    func setRecordingEnabled(_ value: Bool, context: HistoryContext) {
        guard accepts(context) else { return }
        generation += 1; progressWrittenAt = [:]; recordingEnabled = value
        let current = HistoryContext(ownerKey: context.ownerKey, generation: generation)
        enqueue(current) { try await $0.setRecordingEnabled(value) }
    }
    func waitForWrites() async { await tail?.value }

    private func enqueue(_ context: HistoryContext, _ operation: @escaping @Sendable (BrowsingHistoryDatabase) async throws -> HistoryArchive) {
        guard accepts(context), let db = database else { return }
        let previous = tail
        tail = Task { [weak self] in
            await previous?.value
            guard let self, self.accepts(context) else { return }
            do {
                let archive = try await operation(db)
                guard self.accepts(context) else { return }
                self.apply(archive); self.error = nil
            } catch {
                if self.accepts(context) { self.error = "浏览历史保存失败，请检查手机可用空间后重试。"; self.diagnostics?.note(area: .history, code: .storage) }
            }
        }
    }
    private func apply(_ archive: HistoryArchive) {
        records = archive.records; checkpoints = archive.checkpoints; recordingEnabled = archive.recordingEnabled
    }
}

/// Fetch saved IDs through the current account before displaying media. A local
/// history entry is evidence of a visit, never evidence of current permission.
enum HistoryMediaPolicy {
    static func ordered(_ media: [MediaItem], ids: [Int], blockedTags: Set<String>, filter: FeedFilter? = nil, followingIDs: Set<Int>? = nil, allowedMask: Int = 1) -> [MediaItem] {
        let byID = Dictionary(media.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<Int>()
        return ids.compactMap { id in
            guard seen.insert(id).inserted, let item = byID[id], item.isSupported, item.mediaURL != nil,
                  TagPolicy.verdict(names: item.tagNames, blocked: blockedTags) == .allowed else { return nil }
            guard let level = item.browsingLevel, level > 0, level & ~allowedMask == 0 else { return nil }
            if let filter {
                guard filter.effectiveKind == .all || (filter.effectiveKind == .video) == item.isVideo else { return nil }
                if let range = filter.videoDurationRange, !range.contains(item.durationSeconds) { return nil }
                if filter.onlyPG, item.browsingLevel != 1 { return nil }
            }
            if let followingIDs {
                guard let creatorID = item.creatorID, followingIDs.contains(creatorID) else { return nil }
            }
            return item
        }
    }
}

extension TimelineCheckpoint {
    static func window(lane: HistoryLane, filter: FeedFilter, items: [MediaItem], focusedID: Int) -> TimelineCheckpoint? {
        guard let index = items.firstIndex(where: { $0.id == focusedID }) else { return nil }
        // One ID hydration request normally restores this bounded reading segment.
        let start = max(0, index - 8), end = min(items.count, max(index + 1, start + 30))
        return .init(lane: lane, filter: filter, ids: Array(items[start..<end].map(\.id)), focusedID: focusedID, updatedAt: Date())
    }
}

struct HistoryPlaybackRequest: Identifiable {
    let id = UUID()
    let ids: [Int]
    let focusedID: Int
    let context: HistoryContext
    var lane: HistoryLane?
    var filter: FeedFilter?
    var resumePosition: Double?
    init(ids: [Int], focusedID: Int, context: HistoryContext, resumePosition: Double?) {
        let index = ids.firstIndex(of: focusedID) ?? 0
        let start = max(0, index - 15), end = min(ids.count, max(index + 1, start + 60))
        self.ids = Array(ids[start..<end]); self.focusedID = focusedID; self.context = context; self.resumePosition = resumePosition
    }
    init(checkpoint: TimelineCheckpoint, context: HistoryContext, resumePosition: Double?) {
        ids = checkpoint.ids; focusedID = checkpoint.focusedID; self.context = context
        lane = checkpoint.lane; filter = checkpoint.filter; self.resumePosition = resumePosition
    }
}

