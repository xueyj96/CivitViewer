#if DEBUG && targetEnvironment(simulator)
import Foundation
import CryptoKit

/// Height-audit fixtures use the production history/offline schemas and pages.
/// This opt-in route never reads Application Support or downloads fixture bytes.
@MainActor enum ViewportAuditQA {
    static var enabled: Bool {
        CollectionPagingQA.enabled && ProcessInfo.processInfo.arguments.contains("--qa-height-audit")
    }
    static let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CivitViewportAuditQA", isDirectory: true)
    static var historyRoot: URL { root.appendingPathComponent("History", isDirectory: true) }
    static var offlineRoot: URL { root.appendingPathComponent("Offline", isDirectory: true) }
    private static var preparation: Task<Void, Error>?
    private static let defaultsName = "CivitViewportAuditQA"
    private static let defaults = UserDefaults(suiteName: defaultsName)!
    static func dismissals() -> TimelineCheckpointDismissals { TimelineCheckpointDismissals(defaults: defaults) }

    static func prepare(session: SiteSession) async throws {
        guard enabled else { return }
        if let preparation { try await preparation.value; return }
        let task = Task { @MainActor in try await seedAndBind(session: session) }
        preparation = task
        try await task.value
    }

    private static func seedAndBind(session: SiteSession) async throws {
        guard enabled, session.account?.id == CollectionPagingQA.ownerID else { throw ClientError.invalidResponse }
        let items = CollectionPagingQA.items
        guard items.count == 6, Set(items.map(\.id)).count == 6, items[2].isVideo else { throw ClientError.invalidResponse }
        let fm = FileManager.default
        // Reset only this opt-in synthetic store and its prompt preferences.
        // Previous routes must not consume the next route's seeded resume offer.
        defaults.removePersistentDomain(forName: defaultsName)
        if fm.fileExists(atPath: historyRoot.path) { try fm.removeItem(at: historyRoot) }
        let owner = CollectionPagingQA.ownerID
        let offlineKey = SHA256.hash(data: Data(String(owner).utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = offlineRoot.appendingPathComponent(offlineKey, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date()
        var records: [OfflineRecord] = []
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            var record = OfflineRecord(id: item.id, video: item.isVideo, username: item.username, creatorID: item.creatorID,
                                       browsingLevel: item.browsingLevel, collectionIDs: [CollectionPagingQA.collection.id], cloudState: .saved)
            record.fileState = .ready; record.savedAt = now.addingTimeInterval(-Double(index) * 60)
            record.checkedAt = now; record.tagNames = item.tagNames
            guard let source = item.offlineMediaURL else { throw ClientError.invalidResponse }
            record.bytes = try copyLocalFixture(source, to: folder.appendingPathComponent(record.fileName))
            if item.isVideo, let poster = item.offlinePosterURL {
                record.bytes += try copyLocalFixture(poster, to: folder.appendingPathComponent(record.posterName))
            }
            records.append(record)
        }
        let manifest = OfflineManifest(accountID: owner, records: records, lastScan: now)
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("index.json"), options: .atomic)

        // Populate disk before the first shared bind so resumeOffers sees a past
        // reading segment rather than a checkpoint written by the current visit.
        let historyKey = BrowsingHistory.key(owner)
        let db = BrowsingHistoryDatabase(fileURL: historyRoot.appendingPathComponent(historyKey).appendingPathComponent("history.json"), ownerKey: historyKey)
        _ = try await db.setRecordingEnabled(true)
        for (index, item) in items.enumerated() {
            _ = try await db.record(HistoryRecord(id: item.id, kind: item.isVideo ? .video : .image, authorName: item.username,
                                                 creatorID: item.creatorID, viewedAt: now.addingTimeInterval(-Double(index + 1) * 60),
                                                 positionSeconds: item.isVideo ? 2 : nil, durationSeconds: item.isVideo ? max(3, item.durationSeconds ?? 30) : nil))
        }
        _ = try await db.checkpoint(.init(lane: .recommendation, filter: FeedFilter(), ids: items.map(\.id),
                                          focusedID: items[2].id, updatedAt: now,
                                          continuation: TimelineContinuation(cursor: nil, capturedAt: now, reachedEnd: true)))
        try Task.checkCancellation()
        await BrowsingHistory.shared.bind(ownerID: owner, identity: session.tagLibraryIdentity)
        guard BrowsingHistory.shared.ready, BrowsingHistory.shared.records.count == 6 else { throw ClientError.invalidResponse }
        OfflineLibrary.shared.setActive(false)
        OfflineLibrary.shared.bind(accountID: owner, session: session)
        OfflineLibrary.shared.setActive(false)
        guard OfflineLibrary.shared.readyCount == 6 else { throw ClientError.invalidResponse }
    }

    private static func copyLocalFixture(_ source: URL, to destination: URL) throws -> Int64 {
        guard source.isFileURL,
              let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 32 * 1_024 * 1_024 else { throw ClientError.invalidResponse }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard data.count == size else { throw ClientError.invalidResponse }
        try data.write(to: destination, options: .atomic)
        return Int64(data.count)
    }

    static func mediaItems(ids: [Int]) -> [MediaItem] {
        guard enabled, !ids.isEmpty, ids.count <= 30 else { return [] }
        let byID = Dictionary(CollectionPagingQA.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }
    static func page(filter: FeedFilter, cursor: String?, creator: Creator? = nil) -> MediaPage {
        let items = cursor == nil ? CollectionPagingQA.items.filter {
            (filter.effectiveKind == .all || $0.isVideo == (filter.effectiveKind == .video)) &&
            (!filter.onlyPG || $0.browsingLevel == 1) && (creator == nil || $0.creatorID == creator?.id)
        } : []
        return MediaPage(items: items, metadata: .init(nextCursor: nil))
    }
    static func searchPage(target: MediaSearchTarget, filter: FeedFilter, cursor: String?) throws -> MediaPage {
        let page = page(filter: filter, cursor: cursor)
        let matches: [MediaItem]
        switch target {
        case .author(let author): matches = page.items.filter { $0.creatorID == author.id && $0.username?.lowercased() == author.username.lowercased() }
        case .tag(let tag): matches = page.items.filter { $0.tags?.contains(where: { $0.id == tag.id }) == true }
        case .title(let keyword): matches = MediaSearchText.matchesPrefix("Paging Pattern", keyword: keyword) ? page.items : []
        case .combined(let criteria):
            guard criteria.valid else { throw ClientError.invalidResponse }
            let titleMatches = criteria.normalizedText.isEmpty || MediaSearchText.matchesPrefix("Paging Pattern", keyword: criteria.normalizedText)
            matches = titleMatches ? try page.items.filter { try criteria.matches($0) } : []
        }
        return MediaPage(items: matches, metadata: page.metadata)
    }
}
#endif
