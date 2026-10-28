import Foundation
import Combine
import CryptoKit

@MainActor protocol TagLibrarySource: AnyObject {
    var tagLibraryOwnerID: Int? { get }
    var tagLibraryIdentity: String { get }
    func remoteTagPage(prefix: String, page: Int, limit: Int) async throws -> [SearchTag]
    func remoteCommonTags() async throws -> [SearchTag]
}

/// Metadata only. Separate from media LRU and offline favorite files.
@MainActor final class LocalTagLibrary: ObservableObject {
    static let shared = LocalTagLibrary()
    @Published private(set) var stats = TagLibraryStats()
    @Published private(set) var status = "正在打开本地标签库"
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var revision = 0
    private var database: LocalTagDatabase?
    private var ownerKey: String?
    private var generation = 0
    private var job: Task<Void, Never>?
    private var active = false
    private var pausedByUser = false
    private var retryAfter = Date.distantPast
    private let rootURL: URL
    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CivitTagLibrary", isDirectory: true)
    }
    var autoEnabled: Bool { UserDefaults.standard.object(forKey: "tagLibraryAuto") as? Bool ?? true }
    var wifiOnly: Bool { UserDefaults.standard.object(forKey: "tagLibraryWiFi") as? Bool ?? true }
    var canNetwork: Bool { wifiOnly ? OfflineLibrary.shared.unmeteredMetadataNetwork : OfflineLibrary.shared.metadataNetworkConnected }

    func bind(ownerID: Int?) async {
        guard !Task.isCancelled else { return }
        let key = Self.key(ownerID)
        guard ownerKey != key || database == nil else { return }
        pause(reason: "切换标签库")
        ownerKey = key; database = nil; stats = .init(); error = nil; retryAfter = .distantPast; pausedByUser = false
        let folder = rootURL.appendingPathComponent(key, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var value = URLResourceValues(); value.isExcludedFromBackup = true
            var mutable = folder; try mutable.setResourceValues(value)
        } catch { self.error = LocalTagError.database.localizedDescription; status = "标签库无法打开"; return }
        let db = LocalTagDatabase(fileURL: folder.appendingPathComponent("tags.sqlite"))
        database = db; let token = generation
        do {
            let value = try await db.stats()
            guard token == generation, ownerKey == key else { return }
            stats = value; revision += 1; status = value.stored == 0 ? "首次同步待开始" : "本地标签库可用"
        } catch { if token == generation { self.error = error.localizedDescription; status = "标签库无法读取" } }
    }

    func setActive(_ value: Bool) {
        active = value
        if !value { pause(reason: "已暂停，回到前台后继续") }
    }
    func pause(reason: String = "同步已暂停", userInitiated: Bool = false) {
        if userInitiated { pausedByUser = true }
        generation += 1; job?.cancel(); job = nil; busy = false; status = reason
    }
    func requestSync(source: any TagLibrarySource, prefix: String? = nil, manual: Bool = false) {
        guard active else { status = "回到前台后可同步"; return }
        guard manual || autoEnabled else { return }
        guard manual || !pausedByUser else { return }
        guard canNetwork else { status = wifiOnly ? "等待 Wi-Fi 同步标签" : "离线，仍可查询本地标签"; return }
        guard Date() >= retryAfter else { status = "同步冷却中，已有标签仍可查询"; return }
        if manual { pausedByUser = false }
        guard ownerKey == Self.key(source.tagLibraryOwnerID), database != nil else { status = "正在准备当前账号的标签库"; return }
        if busy {
            guard prefix != nil else { return }
            pause(reason: "优先同步查询前缀")
        }
        let token = generation, identity = source.tagLibraryIdentity
        busy = true
        job = Task(priority: .utility) { [weak self] in
            await self?.synchronize(source: source, preferred: prefix, token: token, identity: identity)
        }
    }
    func waitForSync() async { await job?.value }

    func page(ownerID: Int?, keyword: String, common: Bool, cursor: LocalTagCursor?, limit: Int = 20) async throws -> LocalTagPage {
        try Task.checkCancellation()
        let key = Self.key(ownerID)
        guard ownerKey == key, let db = database else { throw LocalTagError.contextChanged }
        let result = try await db.query(prefix: keyword, common: common, after: cursor, context: key, limit: limit)
        try Task.checkCancellation()
        guard ownerKey == key, database === db else { throw LocalTagError.contextChanged }
        return result
    }
    func legacyPage(ownerID: Int?, keyword: String, page: Int, common: Bool = false) async throws -> [SearchTag] {
        guard (1...1000).contains(page) else { throw LocalTagError.invalidPage }
        var cursor: LocalTagCursor?
        for step in 1...page {
            let value = try await self.page(ownerID: ownerID, keyword: keyword, common: common, cursor: cursor, limit: common ? 200 : 20)
            if step == page { return value.items }
            guard let next = value.next else { return [] }; cursor = next
        }
        return []
    }
    func rememberDiscovered(ownerID: Int?, tags: [SearchTag], common: Bool) async throws {
        try Task.checkCancellation()
        let key = Self.key(ownerID)
        guard ownerKey == key, let db = database else { throw LocalTagError.contextChanged }
        let run = generation
        try await db.mergeDiscovered(tags, common: common, now: Date())
        try Task.checkCancellation()
        guard run == generation, ownerKey == key, database === db else { throw LocalTagError.contextChanged }
        try await refresh(db, run: run)
    }
    func reset(ownerID: Int?) async {
        guard !Task.isCancelled, ownerKey == Self.key(ownerID), let db = database else { return }
        pause(reason: "正在重建标签库")
        let token = generation
        do {
            try await db.reset(); let value = try await db.stats()
            guard token == generation else { return }
            stats = value; error = nil; revision += 1; status = "标签库已清空，等待重新同步"
        } catch { if token == generation { self.error = error.localizedDescription } }
    }

    private func synchronize(source: any TagLibrarySource, preferred: String?, token: Int, identity: String) async {
        guard token == generation, !Task.isCancelled else { return }
        let run = generation
        defer { if run == generation { busy = false; job = nil } }
        guard active, canNetwork, ownerKey == Self.key(source.tagLibraryOwnerID), let db = database else { return }
        error = nil
        do {
            try check(source: source, identity: identity, run: run)
            if stats.lastCommonSync.map({ Date().timeIntervalSince($0) >= 86_400 }) ?? true {
                status = "正在同步常用标签"
                let common = try await source.remoteCommonTags()
                try check(source: source, identity: identity, run: run)
                try await db.storeCommon(common, now: Date())
                try await refresh(db, run: run)
            }
            for _ in 0..<2 {
                try check(source: source, identity: identity, run: run)
                guard let work = try await db.nextWork(now: Date(), refreshAfter: 86_400, preferredPrefix: preferred) else { status = "已完成本轮复查，等待下次更新"; return }
                status = "同步 \(work.prefix.uppercased()) · 第 \(work.page) 页"
                let tags = try await source.remoteTagPage(prefix: work.prefix, page: work.page, limit: 200)
                try check(source: source, identity: identity, run: run)
                let completed = try await db.commit(work: work, tags: tags, pageSize: 200, now: Date())
                try await refresh(db, run: run)
                if preferred != nil && completed { break }
                try await Task.sleep(for: .seconds(3))
            }
            status = "本批已保存，下批从断点继续"; retryAfter = .distantPast
        } catch is CancellationError { /* The completed page checkpoint is durable. */ }
        catch {
            guard run == generation else { return }
            self.error = error.localizedDescription; status = "同步暂停，已有标签仍可查询"
            if case ClientError.http(429) = error { retryAfter = Date().addingTimeInterval(300) }
            else { retryAfter = Date().addingTimeInterval(60) }
        }
    }
    private func check(source: any TagLibrarySource, identity: String, run: Int) throws {
        try Task.checkCancellation()
        guard run == generation, identity == source.tagLibraryIdentity else { throw LocalTagError.contextChanged }
        guard active, canNetwork else { throw CancellationError() }
    }
    private func refresh(_ db: LocalTagDatabase, run: Int) async throws {
        let value = try await db.stats()
        guard run == generation else { throw CancellationError() }
        stats = value; revision += 1
    }
    private static func key(_ ownerID: Int?) -> String {
        SHA256.hash(data: Data("https://civitai.red|\(ownerID.map(String.init) ?? "anonymous")".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
