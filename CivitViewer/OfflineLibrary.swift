import Foundation
import Combine
import CryptoKit
import Network

/// Durable, account-scoped files. Browsing-cache eviction never touches this directory.
@MainActor final class OfflineLibrary: ObservableObject {
    static let shared = OfflineLibrary()
    @Published private(set) var accountID: Int?
    @Published private(set) var records: [OfflineRecord] = []
    @Published private(set) var diskBytes: Int64 = 0
    @Published private(set) var diskUsageKnown = false
    @Published private(set) var busy = false
    @Published private(set) var status = "等待账号"
    @Published private(set) var currentID: Int?
    @Published private(set) var progress: Double?
    @Published private(set) var lastScan: Date?
    private var omittedIDs = Set<Int>()
    private var worker: Task<Void, Never>?
    private var generation = 0
    private var active = true
    private var connected = false
    private var unmetered = false
    private var rescanRequested = false
    private var healthy = true
    private var lastPersisted = Date.distantPast
    private var indexBytes: Int64 = 0
    private var repairReserved: Int64 = 0
    private var repairFamilyBytes: [String: Int64] = [:]
    private weak var session: SiteSession?
    private let monitor = NWPathMonitor()
    private let root: URL
    private(set) var directory: URL?
    var autoEnabled: Bool { UserDefaults.standard.object(forKey: "offlineAutoSave") as? Bool ?? true }
    var wifiOnly: Bool { UserDefaults.standard.object(forKey: "offlineWifiOnly") as? Bool ?? true }
    var capacity: Int64 {
        let value = UserDefaults.standard.object(forKey: "offlineLimitGB") as? Int ?? 10
        return Int64([1,5,10,20,50].contains(value) ? value : 10) * 1_000_000_000
    }
    var readyCount: Int { records.filter { $0.fileState == .ready }.count }
    var canNetwork: Bool { connected && (!wifiOnly || unmetered) }
    var metadataNetworkConnected: Bool { connected }
    var unmeteredMetadataNetwork: Bool { connected && unmetered }
    var mediaItems: [MediaItem] {
        guard let directory else { return [] }
        return records.filter { $0.fileState == .ready && FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.fileName).path) }.map { $0.media(in: directory) }
    }

    private init() {
        #if DEBUG && targetEnvironment(simulator)
        if ViewportAuditQA.enabled {
            root = ViewportAuditQA.offlineRoot
            active = false; status = "本地高度检查夹具；同步已停用"
            return // Do not start the production network monitor for this isolated run.
        }
        #endif
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CivitOffline", isDirectory: true)
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let wifi = connected && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)) && !path.isExpensive && !path.isConstrained
            Task { @MainActor in
                guard let self else { return }
                let wasAllowed = self.canNetwork
                self.connected = connected; self.unmetered = wifi
                if wasAllowed && !self.canNetwork && self.busy { self.pause(reason: connected ? "等待 Wi-Fi" : "离线，可浏览已保存作品") }
                if !wasAllowed && self.canNetwork && self.active && self.autoEnabled, let session = self.session { self.requestSync(session: session) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "CivitViewer.offline-network"))
    }

    func bind(accountID: Int?, session: SiteSession) {
        self.session = session
        guard self.accountID != accountID else { return }
        pause(reason: "切换账号")
        self.accountID = accountID; records = []; omittedIDs = []; lastScan = nil; diskBytes = 0; indexBytes = 0; directory = nil; healthy = true; lastPersisted = .distantPast
        diskUsageKnown = false; repairFamilyBytes = [:]
        guard let accountID else { status = "登录后可管理当前账号的离线收藏"; return }
        let key = SHA256.hash(data: Data(String(accountID).utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = root.appendingPathComponent(key, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var target = folder; try target.setResourceValues(values)
            directory = folder
            let index = folder.appendingPathComponent("index.json")
            if FileManager.default.fileExists(atPath: index.path) {
                let manifest = try JSONDecoder().decode(OfflineManifest.self, from: Data(contentsOf: index))
                guard manifest.version == 1 && manifest.accountID == accountID else { throw ClientError.invalidResponse }
                records = manifest.records.filter { $0.id > 0 }; omittedIDs = manifest.omittedIDs; lastScan = manifest.lastScan
            }
            status = reconcileFiles() ? "已读取本地收藏" : "离线空间暂时无法统计，已暂停写入"
        } catch { healthy = false; status = "本地收藏目录读取失败，已停止自动写入" }
    }

    func setActive(_ value: Bool) {
        #if DEBUG && targetEnvironment(simulator)
        if ViewportAuditQA.enabled {
            active = false
            if busy { pause(reason: "本地高度检查夹具；同步已停用") }
            return
        }
        #endif
        active = value
        if !value { pause(reason: "后台已暂停，回到 App 后继续") }
        else if autoEnabled, let session { requestSync(session: session) }
    }
    func pause(reason: String = "已暂停") {
        generation += 1; worker?.cancel(); worker = nil; busy = false; currentID = nil; progress = nil; status = reason
    }
    func resumeAll(session: SiteSession, includeRemovedCopies: Bool = false) {
        if includeRemovedCopies { omittedIDs = []; try? persist(force: true) }
        requestSync(session: session, manual: true)
    }

    func requestSync(session: SiteSession, manual: Bool = false) {
        #if DEBUG && targetEnvironment(simulator)
        if ViewportAuditQA.enabled { return }
        #endif
        self.session = session
        guard repairReserved == 0 else { return }
        guard manual || autoEnabled else { return }
        guard active, healthy, let owner = accountID, session.account?.id == owner, session.hasCollectionAccess else { return }
        guard canNetwork else { status = connected ? "等待 Wi-Fi" : "离线，可浏览已保存作品"; return }
        if busy { rescanRequested = true; return }
        guard reconcileFiles() else { status = "离线空间暂时无法统计，已暂停下载和转换"; return }
        let revision = generation
        busy = true; status = "正在扫描全部收藏…"
        worker = Task { [weak self] in
            guard let self else { return }
            defer {
                if revision == self.generation {
                    self.busy = false; self.currentID = nil; self.progress = nil; self.worker = nil
                    if self.rescanRequested { self.rescanRequested = false; self.requestSync(session: session) }
                }
            }
            do { try await self.sync(session: session, owner: owner, revision: revision) }
            catch is CancellationError { if revision == self.generation { self.status = "已暂停" } }
            catch { if revision == self.generation { self.status = "同步未完成，已保存文件保留，可稍后重试"; try? self.persist(force: true) } }
        }
    }

    private func check(_ owner: Int, _ revision: Int) throws {
        try Task.checkCancellation()
        guard accountID == owner, generation == revision, active else { throw CancellationError() }
        guard canNetwork else { throw CancellationError() }
    }

    func refreshTags(session: SiteSession) async {
        guard !busy, active, canNetwork, let owner = accountID, session.account?.id == owner else { return }
        let ids = records.filter { $0.tagNames == nil }.map(\.id)
        guard !ids.isEmpty else { return }
        busy = true; let revision = generation
        defer {
            if revision == generation {
                busy = false
                if rescanRequested { rescanRequested = false; requestSync(session: session) }
            }
        }
        for offset in stride(from: 0, to: ids.count, by: 30) {
            do {
                try check(owner, revision)
                let batch = Array(ids[offset..<min(offset + 30, ids.count)])
                let items = try await session.mediaItems(ids: batch)
                try check(owner, revision)
                for item in items {
                    if let names = item.tagNames, let index = records.firstIndex(where: { $0.id == item.id }) { records[index].tagNames = names }
                }
                try persist(force: true)
            } catch { break }
        }
        if revision == generation { status = "收藏标签已更新；仍有 \(records.filter { $0.tagNames == nil }.count) 项待核实" }
    }

    private func sync(session: SiteSession, owner: Int, revision: Int) async throws {
        try await session.refreshCollections(); try check(owner, revision)
        var sources: [Int: MediaItem] = [:], membership: [Int: Set<Int>] = [:]
        for collection in session.collections {
            var cursor: String?, cursors = Set<String>()
            repeat {
                try check(owner, revision)
                let page = try await session.collectionPage(id: collection.id, filter: FeedFilter(), cursor: cursor, allAccessibleLevels: true, includeTags: true)
                try check(owner, revision)
                for id in page.metadata.sourceIDs ?? page.items.map(\.id) { membership[id, default: []].insert(collection.id) }
                for item in page.items where item.id > 0 && item.isSupported {
                    sources[item.id] = item
                    if let index = records.firstIndex(where: { $0.id == item.id }) {
                        records[index].username = item.username; records[index].creatorID = item.creatorID
                        if let names = item.tagNames { records[index].tagNames = names }
                    } else if !omittedIDs.contains(item.id) {
                        records.append(.init(id: item.id, video: item.isVideo, username: item.username, creatorID: item.creatorID, browsingLevel: item.browsingLevel, collectionIDs: [collection.id], cloudState: .saved))
                        records[records.count - 1].tagNames = item.tagNames
                    }
                }
                status = "已扫描 \(sources.count) 项可访问收藏"
                try persist()
                cursor = page.metadata.nextCursor
                if let cursor, !cursors.insert(cursor).inserted { throw ClientError.invalidResponse }
            } while cursor != nil
        }
        // Only a complete scan may establish missing candidates. Check membership
        // separately because a hidden/unavailable image can be omitted from a grid.
        for id in records.map(\.id) {
            try check(owner, revision)
            guard let index = records.firstIndex(where: { $0.id == id }) else { continue }
            if let folders = membership[id] {
                records[index].collectionIDs = folders; records[index].cloudState = .saved; records[index].checkedAt = Date()
            } else if records[index].cloudState != .localOnly {
                do {
                    let folders = try await session.allSavedMembership(id)
                    try check(owner, revision)
                    if let index = records.firstIndex(where: { $0.id == id }) {
                        records[index].collectionIDs = folders; records[index].cloudState = folders.isEmpty ? .localOnly : .saved; records[index].checkedAt = Date()
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { if let index = records.firstIndex(where: { $0.id == id }) { records[index].cloudState = .unknown } }
            }
        }
        lastScan = Date(); try persist(force: true)
        for id in sources.keys.sorted(by: >) {
            try check(owner, revision)
            guard !omittedIDs.contains(id), let item = sources[id], let index = records.firstIndex(where: { $0.id == id }), records[index].fileState != .ready else { continue }
            let budget = downloadBudget()
            guard budget > 1024 else { status = "离线空间已满或可用空间不足，整理后继续"; try persist(force: true); return }
            currentID = id; progress = nil; status = "正在保存 \(item.isVideo ? "视频" : "图片") #\(id)…"
            do { try await save(item, owner: owner, revision: revision, budget: budget) }
            catch is CancellationError { throw CancellationError() }
            catch MediaDownloadError.limitExceeded { status = "当前作品超过剩余离线空间，扩大上限或整理后继续"; try persist(force: true); return }
            catch { if let index = records.firstIndex(where: { $0.id == id }) { records[index].fileState = .failed }; try persist() }
        }
        reconcileFiles(); try persist(force: true)
        let failed = records.filter { $0.fileState == .failed }.count
        let skipped = Set(sources.keys).intersection(omittedIDs).count
        status = failed == 0 ? (skipped == 0 ? "已保存全部可访问收藏" : "已保存 \(readyCount) 项，按你的设置跳过 \(skipped) 项") : "已保存 \(readyCount) 项，\(failed) 项失败，可重试"
    }

    private func save(_ item: MediaItem, owner: Int, revision: Int, budget: Int64) async throws {
        guard diskUsageKnown else { throw MediaRepairError.storageUnknown }
        guard let directory, let source = item.mediaURL, source.scheme == "https", source.pathExtension.lowercased() != "m3u8",
              let record = records.first(where: { $0.id == item.id }) else { throw ClientError.invalidResponse }
        let target = directory.appendingPathComponent(record.fileName)
        var copied = false
        if let cached = MediaCache.shared.cached(source, video: item.isVideo), let size = try? cached.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
            guard Int64(size) <= budget else { throw MediaDownloadError.limitExceeded }
            copied = (try? FileManager.default.copyItem(at: cached, to: target)) != nil
            if !copied { try? FileManager.default.removeItem(at: target) }
        }
        if !copied {
            let temporary = try await BoundedDownload.fetch(source, maxBytes: budget, reserveBytes: 1_000_000_000) { [weak self] bytes, total in
                Task { @MainActor in
                    guard let self, self.generation == revision, self.currentID == item.id else { return }
                    self.progress = total > 0 ? min(1, Double(bytes) / Double(total)) : nil
                }
            }
            defer { try? FileManager.default.removeItem(at: temporary) }
            try check(owner, revision)
            let size = Int64(try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            // The temporary file already consumes free space; only the logical
            // quota needs adding again before an atomic same-volume move.
            guard size > 0, size <= max(0, capacity - diskBytes) else { throw MediaDownloadError.limitExceeded }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temporary, to: target)
        }
        try check(owner, revision)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
        if let index = records.firstIndex(where: { $0.id == item.id }) {
            records[index].fileState = .ready; records[index].savedAt = Date()
        }
        refreshFileSize(item.id); try persist()
        if item.isVideo, let poster = item.posterURL, downloadBudget() > 1024 {
            let posterTarget = directory.appendingPathComponent(record.posterName)
            if !FileManager.default.fileExists(atPath: posterTarget.path) {
                if let file = try? await BoundedDownload.fetch(poster, maxBytes: min(downloadBudget(), 16 * 1024 * 1024), reserveBytes: 1_000_000_000) {
                    defer { try? FileManager.default.removeItem(at: file) }
                    try check(owner, revision)
                    try? FileManager.default.moveItem(at: file, to: posterTarget)
                    try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: posterTarget.path)
                }
            }
        }
        refreshFileSize(item.id); try persist()
    }

    func accept(_ update: SavedMembershipUpdate) {
        guard update.accountID == accountID, let index = records.firstIndex(where: { $0.id == update.imageID }) else { return }
        records[index].collectionIDs = update.collectionIDs
        records[index].cloudState = update.collectionIDs.isEmpty ? .unknown : .saved
        records[index].checkedAt = Date(); try? persist(force: true)
    }
    func opened(_ id: Int) {
        if let index = records.firstIndex(where: { $0.id == id }) { records[index].lastOpenedAt = Date(); try? persist() }
    }

    func removeLocal(_ ids: Set<Int>) {
        pause(reason: "正在清理本地副本…")
        guard let directory, healthy else { return }
        omittedIDs.formUnion(ids)
        do {
            try persist(force: true) // Persist exclusions before removing any bytes.
            var removed = Set<Int>()
            let snapshot = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let repairFiles = MediaRepairStore.familySnapshot(snapshot).files
            for record in records where ids.contains(record.id) {
                do {
                    let stem = MediaRepairStore.stem(directory.appendingPathComponent(record.fileName))
                    for file in repairFiles[stem] ?? [] { try FileManager.default.removeItem(at: file) }
                    for name in [record.fileName, record.posterName] {
                        let file = directory.appendingPathComponent(name)
                        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                    }
                    removed.insert(record.id)
                } catch { /* Retain the record if a file could not be removed. */ }
            }
            records.removeAll { removed.contains($0.id) }; reconcileFiles(); try persist(force: true)
            status = removed.count == ids.count ? "已清理 \(removed.count) 项本地副本，云端收藏保留" : "部分文件暂时无法清理，请稍后重试"
        } catch { status = "本地目录未能保存，清理已停止" }
    }

    func cleanUnfavorited(session: SiteSession, ids: Set<Int>? = nil) {
        guard !busy, canNetwork, let owner = accountID, session.account?.id == owner, session.hasCollectionAccess else { status = "请联网后核对并清理"; return }
        let candidates = records.filter { ids?.contains($0.id) ?? true }.map(\.id)
        let revision = generation; busy = true
        worker = Task {
            var confirmed = Set<Int>()
            defer { if generation == revision { busy = false; worker = nil } }
            for (offset, id) in candidates.enumerated() {
                do {
                    try check(owner, revision); status = "正在核对 \(offset + 1) / \(candidates.count)…"
                    let folders = try await session.allSavedMembership(id)
                    try check(owner, revision)
                    if folders.isEmpty { confirmed.insert(id) }
                    if let index = records.firstIndex(where: { $0.id == id }) { records[index].collectionIDs = folders; records[index].cloudState = folders.isEmpty ? .localOnly : .saved; records[index].checkedAt = Date() }
                } catch is CancellationError { return }
                catch { if let index = records.firstIndex(where: { $0.id == id }) { records[index].cloudState = .unknown } }
            }
            guard generation == revision else { return }
            try? persist(force: true)
            if !confirmed.isEmpty { removeLocal(confirmed) }
            else { status = "没有确认可清理的已取消收藏；待核对文件保留" }
        }
    }

    func clearAll() {
        UserDefaults.standard.set(false, forKey: "offlineAutoSave")
        if !healthy, let directory {
            pause(reason: "正在清理离线目录…")
            do {
                for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) { try FileManager.default.removeItem(at: file) }
                records = []; omittedIDs = []; lastScan = nil; diskBytes = 0; indexBytes = 0; healthy = true
                _ = reconcileFiles()
                try persist(force: true); status = "离线目录已清理，自动保存已关闭"
            } catch { status = "部分本地文件无法清理，请稍后重试" }
            return
        }
        removeLocal(Set(records.map(\.id)))
    }

    private func downloadBudget() -> Int64 {
        guard diskUsageKnown, let directory else { return 0 }
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return OfflineQuota.downloadBudget(used: diskBytes + repairReserved, limit: capacity, free: values?.volumeAvailableCapacity.map(Int64.init))
    }
    func ownsRepairSource(_ source: URL) -> Bool {
        guard healthy, let directory, source.isFileURL,
              source.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return false }
        return records.contains { $0.fileName == source.lastPathComponent && $0.fileState == .ready }
    }
    func reserveRepairBudget() -> Int64 {
        // Stop a previously admitted download before reserving output bytes.
        // Its old generation cannot commit after pause returns.
        if busy { pause(reason: "正在修复离线视频，收藏下载稍后继续") }
        guard reconcileFiles() else { return 0 }
        let budget = min(536_870_912, downloadBudget())
        repairReserved += budget
        return budget
    }
    func releaseRepairBudget(_ bytes: Int64) {
        repairReserved = max(0, repairReserved - bytes)
        guard reconcileFiles() else { return }
        if repairReserved == 0, autoEnabled, active, let session { requestSync(session: session) }
    }
    func refreshRepairSizes() { if reconcileFiles() { try? persist(force: true) } }
    @discardableResult private func reconcileFiles() -> Bool {
        guard let directory, let snapshot = try? OfflineDiskSnapshot.read(directory: directory) else {
            diskUsageKnown = false; return false // Keep prior bytes and ready states on UNKNOWN.
        }
        let files = snapshot.files
        let repairBytes = MediaRepairStore.familySnapshot(files, sizes: snapshot.sizes).bytes
        var known = Set(records.map(\.id))
        // Recover files left by an interrupted index write into the "待核对" group.
        for file in files where ["img", "mp4"].contains(file.pathExtension) && !file.lastPathComponent.contains(".poster.") {
            guard let id = Int(file.deletingPathExtension().lastPathComponent), id > 0, !known.contains(id) else { continue }
            known.insert(id)
            let date = snapshot.created[file.standardizedFileURL.path]
            var record = OfflineRecord(id: id, video: file.pathExtension == "mp4", username: nil, creatorID: nil, browsingLevel: nil, collectionIDs: [], cloudState: .unknown)
            record.savedAt = date; records.append(record)
        }
        for index in records.indices {
            let file = directory.appendingPathComponent(records[index].fileName)
            let size = snapshot.sizes[file.standardizedFileURL.path] ?? 0 // Searched and absent in a complete snapshot.
            let poster = snapshot.sizes[directory.appendingPathComponent(records[index].posterName).standardizedFileURL.path] ?? 0
            records[index].bytes = size + poster + (repairBytes[MediaRepairStore.stem(file)] ?? 0)
            if size > 0 { records[index].fileState = .ready }
            else if records[index].fileState == .ready { records[index].fileState = .pending }
        }
        records.removeAll { omittedIDs.contains($0.id) && $0.bytes == 0 }
        diskBytes = snapshot.totalBytes
        indexBytes = snapshot.sizes[directory.appendingPathComponent("index.json").standardizedFileURL.path] ?? 0
        repairFamilyBytes = repairBytes; diskUsageKnown = true
        return true
    }
    private func refreshFileSize(_ id: Int) {
        guard let directory, let index = records.firstIndex(where: { $0.id == id }) else { return }
        let prior = records[index].bytes
        func sizeOrAbsent(_ file: URL) throws -> Int64 {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular, let size = attributes[.size] as? NSNumber, size.int64Value >= 0 else { throw ClientError.invalidResponse }
                return size.int64Value
            } catch {
                let value = error as NSError
                if value.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(value.code) { return 0 }
                throw error
            }
        }
        let file = directory.appendingPathComponent(records[index].fileName)
        guard let media = try? sizeOrAbsent(file), let poster = try? sizeOrAbsent(directory.appendingPathComponent(records[index].posterName)) else { diskUsageKnown = false; return }
        records[index].bytes = media + poster + (repairFamilyBytes[MediaRepairStore.stem(file)] ?? 0)
        diskBytes += records[index].bytes - prior
    }
    private func persist(force: Bool = false) throws {
        guard healthy, let directory, let accountID else { return }
        guard force || Date().timeIntervalSince(lastPersisted) > 2 else { return }
        let manifest = OfflineManifest(accountID: accountID, records: records, omittedIDs: omittedIDs, lastScan: lastScan)
        let file = directory.appendingPathComponent("index.json")
        try JSONEncoder().encode(manifest).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? indexBytes
        diskBytes += size - indexBytes; indexBytes = size
        lastPersisted = Date()
    }
}
