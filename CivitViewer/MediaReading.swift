import Foundation

@MainActor protocol FeedPageReading: AnyObject {
    var feedIdentity: String { get }
    var tagEvidenceIdentity: String { get }
    var siteRetryAvailableAt: Date? { get }
    func videoDurationMetadata(ids: [Int], postIDs: [Int], onlyPG: Bool) async throws -> [VideoDurationRecord]
    func mediaPage(filter: FeedFilter, cursor: String?, creator: Creator?, followed: Bool, includeTags: Bool) async throws -> MediaPage
    func collectionPage(id: Int, filter: FeedFilter, cursor: String?, allAccessibleLevels: Bool, includeTags: Bool) async throws -> MediaPage
    func searchMediaPage(target: MediaSearchTarget, filter: FeedFilter, cursor: String?, includeTags: Bool) async throws -> MediaPage
}

@MainActor protocol HistoryMediaReading: AnyObject {
    var feedIdentity: String { get }
    var followingMemberIDs: Set<Int> { get }
    func mediaItems(ids: [Int], includeTags: Bool) async throws -> [MediaItem]
    func creator(username: String) async throws -> Creator
}

@MainActor protocol TimelineReading: FeedPageReading, HistoryMediaReading {
    var account: Account? { get }
    var tagLibraryOwnerID: Int? { get }
}

// Read-only doubles and readers without duration support retain UNKNOWN values.
extension FeedPageReading {
    var tagEvidenceIdentity: String { feedIdentity }
    var siteRetryAvailableAt: Date? { nil }
    func videoDurationMetadata(ids: [Int], postIDs: [Int], onlyPG: Bool) async throws -> [VideoDurationRecord] { [] }

    /// Saved reading segments contain at most 30 works. Restore both bounded
    /// batches before applying duration policy and reusing the segment's cursor.
    func enrichRestoredVideoDurations(_ items: [MediaItem], filter: FeedFilter, isCurrent: @MainActor () -> Bool) async throws -> [MediaItem] {
        guard filter.videoDurationRange != nil else { return items }
        var result = items
        let limit = min(30, items.count)
        for start in stride(from: 0, to: limit, by: 20) {
            let end = min(start + 20, limit)
            let page = MediaPage(items: Array(items[start..<end]), metadata: .init(nextCursor: nil))
            let resolved = try await enrichVideoDurations(in: page, filter: filter, isCurrent: isCurrent)
            result.replaceSubrange(start..<end, with: resolved.items)
        }
        return result
    }

    /// At most one metadata request for the first 20 unknown videos with original post IDs.
    func enrichVideoDurations(in page: MediaPage, filter: FeedFilter, isCurrent: @MainActor () -> Bool = { true }) async throws -> MediaPage {
        guard filter.videoDurationRange != nil else { return page }
        let identity = feedIdentity
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard identity == feedIdentity, isCurrent() else { throw CancellationError() }
        }
        try checkCurrent()
        let batch = VideoDurationBatch(items: page.items)
        guard !batch.ids.isEmpty else { return page }
        var result = page
        do {
            let records = try await videoDurationMetadata(ids: batch.ids, postIDs: batch.postIDs, onlyPG: filter.onlyPG)
            try checkCurrent()
            result = MediaPage(items: batch.merging(records, into: page.items), metadata: page.metadata, searchProgress: page.searchProgress)
        } catch {
            try checkCurrent()
            result.durationEnrichmentFailed = true
            if case ClientError.http(let status) = error { result.durationEnrichmentHTTPStatus = status }
        }
        return result
    }
}
