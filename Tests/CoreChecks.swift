import Foundation

@main
struct CoreChecks {
    @MainActor static func main() async throws {
        let decoder = JSONDecoder()
        let empty = try decoder.decode(MediaPage.self, from: Data(#"{"items":[],"metadata":{"nextCursor":"feed:1:2"}}"#.utf8))
        var feed = FeedAccumulator(); feed.append(empty)
        precondition(!feed.reachedEnd && feed.cursor == "feed:1:2", "Empty page must retain the continuation")
        let page = try decoder.decode(MediaPage.self, from: Data(#"{"items":[{"id":1,"url":"https://example.com/a.jpeg","type":"image"},{"id":1,"url":"https://example.com/a.jpeg","type":"image"},{"id":2,"url":"https://example.com/b.mp4","type":"video","thumbnail":{"url":"https://example.com/b.webp"}},{"id":3,"url":"https://example.com/c.mp3","type":"audio"},{"id":4,"url":"http://example.com/d.jpg","type":"image"}],"metadata":{"nextCursor":null}}"#.utf8))
        feed.append(page)
        precondition(feed.items.map(\.id) == [1,2], "Deduplicate and reject unsupported/insecure media")
        precondition(feed.reachedEnd, "Only absent cursor ends feed")
        precondition(feed.items[1].isVideo && feed.items[1].posterURL?.path == "/b.webp")
        let opaque = "feed:1744925337225:9173928&x=+?"
        var filter = FeedFilter(); filter.kind = .video; filter.onlyPG = true
        var query = URLComponents(); query.queryItems = filter.query(cursor: opaque, creator: .init(id: 9, username: "A&B", image: nil))
        let reconstructed = URLComponents(string: query.string!)!
        precondition(reconstructed.queryItems?.first(where: { $0.name == "cursor" })?.value == opaque)
        precondition(reconstructed.queryItems?.first(where: { $0.name == "username" })?.value == "A&B")
        precondition(reconstructed.queryItems?.first(where: { $0.name == "type" })?.value == "video")
        precondition(!FeedFilter().query().contains(where: { $0.name == "type" }), "Mixed feed omits type=all")
        let authorDefault = FeedFilter.defaults(for: .creator, kind: .video)
        let authorQuery = authorDefault.query(creator: .init(id: 12, username: "MixFixer", image: nil))
        precondition(authorQuery.contains(.init(name: "period", value: "AllTime")) && authorQuery.contains(.init(name: "sort", value: "Newest")) && authorQuery.contains(.init(name: "type", value: "video")), "Creator landing must query all-time newest in the incoming work's media type")
        var customAuthor = authorDefault; customAuthor.period = "Month"; customAuthor.sort = "Most Collected"; customAuthor.onlyPG = true
        let authorRoundTrip = try decoder.decode(FeedFilter.self, from: JSONEncoder().encode(customAuthor))
        precondition(authorRoundTrip == customAuthor && customAuthor.query().contains(.init(name: "period", value: "Month")) && customAuthor.query().contains(.init(name: "sort", value: "Most Collected")), "Creator defaults must not override explicit range and sort choices")
        precondition(FeedFilter.defaults(for: .discovery).period == "Week" && FeedFilter.defaults(for: .discovery).sort == "Most Reactions" && FeedFilter.defaults(for: .following).period == "AllTime" && FeedFilter.defaults(for: .following).sort == "Newest", "Reset defaults belong to their browsing context")
        let routeAuthor = Creator(id: 12, username: "MixFixer", image: nil)
        precondition(CreatorRoute(creator: routeAuthor, item: feed.items[1]).kind == .video && CreatorRoute(creator: routeAuthor, item: feed.items[0]).kind == .image, "Author navigation must inherit the actual item type even in a mixed timeline")
        let creatorSource = FeedSource.creator(routeAuthor)
        let creatorRequest = FeedStoreRequestKey(identity: "owner:account:1", filter: authorDefault, source: creatorSource)
        precondition(creatorRequest == FeedStoreRequestKey(identity: "owner:account:1", filter: authorDefault, source: creatorSource), "An unchanged owner/account, filter and source retains its request key")
        precondition(creatorRequest != FeedStoreRequestKey(identity: "owner:account:2", filter: authorDefault, source: creatorSource) &&
                     creatorRequest != FeedStoreRequestKey(identity: "owner:account:1", filter: customAuthor, source: creatorSource),
                     "Owner/account or filter changes invalidate the concrete feed result set and cursor")
        precondition(creatorRequest != FeedStoreRequestKey(identity: "owner:account:1", filter: authorDefault,
                     source: .creator(Creator(id: 13, username: "Other", image: nil))),
                     "Changing creator source invalidates the concrete request")
        let collectionRequest = FeedStoreRequestKey(identity: "owner:account:1", filter: authorDefault, source: .collection(12))
        precondition(collectionRequest != FeedStoreRequestKey(identity: "owner:account:1", filter: authorDefault, source: .collection(13)) &&
                     collectionRequest != FeedStoreRequestKey(identity: "owner:account:1", filter: authorDefault, source: .discovery),
                     "Collection identity and source kind invalidate the concrete request")
        precondition(MediaItem.httpsURL("javascript:alert(1)") == nil)
        precondition(Board.legacy.procedure == "leaderboard.getLeadboardLegends" && Board.legacy.webValue == "legend")
        var videos = FeedAccumulator(); videos.append(page, kind: .video)
        precondition(videos.items.map(\.id) == [2], "Video mode must reject image rows even if the server mixes them")
        var images = FeedAccumulator(); images.append(page, kind: .image)
        precondition(images.items.map(\.id) == [1], "Image mode must reject video rows")
        let imageOnlyPage = try decoder.decode(MediaPage.self, from: Data(#"{"items":[{"id":7,"url":"https://example.com/g.jpg","type":"image"}],"metadata":{"nextCursor":"continue:video"}}"#.utf8))
        var filtered = FeedAccumulator(); filtered.append(imageOnlyPage, kind: .video)
        precondition(filtered.items.isEmpty && !filtered.reachedEnd && filtered.cursor == "continue:video", "Filtering a page must keep its continuation")
        let folders = try decoder.decode([SavedCollection].self, from: Data(#"[{"id":10,"name":"Private images","userId":7,"type":"Image","mode":null,"read":"Private"},{"id":11,"name":"Mixed","userId":7,"type":null,"mode":"Bookmark","read":"Private"},{"id":12,"name":"Someone else's","userId":8,"type":"Image","mode":null,"read":"Public"},{"id":13,"name":"Models","userId":7,"type":"Model","mode":null,"read":"Private"},{"id":14,"name":"Contest","userId":7,"type":"Image","mode":"Contest","read":"Public"}]"#.utf8))
        precondition(folders.filter { $0.isPersonalMedia(actorID: 7) }.map(\.id) == [10,11], "Only the actor's personal media folders are editable")
        let change = CollectionSelectionChange(original: [10,11], selected: [11,12,99], editable: [10,11,12], current: [10,11,20])
        precondition(change.additions == [12] && change.removals == [10], "Write only requested, editable deltas; preserve untouched folders and tags")
        precondition(change.isConfirmed(by: [11,12,20]) && !change.isConfirmed(by: [10,11,12]), "A success response alone cannot confirm all requested removals")
        let concurrent = CollectionSelectionChange(original: [10], selected: [10,11], editable: [10,11,12], current: [12])
        precondition(concurrent.additions == [11] && concurrent.removals.isEmpty, "Do not restore externally removed, unedited membership or remove externally added membership")
        let satisfied = CollectionSelectionChange(original: [10], selected: [11], editable: [10,11], current: [11])
        precondition(satisfied.isEmpty, "Read-before-write avoids replaying an already satisfied operation")
        let index = try decoder.decode(CollectionIndexPage.self, from: Data(#"{"collectionItems":[{"id":101,"type":"image","data":{"id":2,"type":"video"}},{"id":102,"type":"model","data":{"id":30}},{"id":103,"type":"image","data":{"id":1,"type":"image"}}],"nextCursor":"opaque:next&cursor"}"#.utf8))
        precondition(index.mediaIDs == [2,1] && index.nextCursor == "opaque:next&cursor", "Collection images include videos and preserve server order while excluding models")
        let shared = CollectionRead<Int>()
        var calls = 0, published: [Int] = []
        let first = shared.task(load: { calls += 1; return 7 }, commit: { published.append($0) })
        let second = shared.task(load: { calls += 1; return 8 }, commit: { published.append($0) })
        let sharedValues = [try await first.value, try await second.value]
        precondition(calls == 1 && sharedValues == [7,7] && published == [7], "Indicator and picker must share one read and publish once")

        let boundary = CollectionRead<Int>()
        let oldStarted = ReadGate(), oldRelease = ReadGate(), newStarted = ReadGate(), newRelease = ReadGate()
        var boundaryCalls = 0, boundaryPublished: [Int] = []
        let old = boundary.task(load: {
            boundaryCalls += 1; oldStarted.open(); await oldRelease.wait(); return 1
        }, commit: { boundaryPublished.append($0) })
        await oldStarted.wait()
        boundary.invalidate()
        let fresh = boundary.task(load: {
            boundaryCalls += 1; newStarted.open(); await newRelease.wait(); return 2
        }, commit: { boundaryPublished.append($0) })
        await newStarted.wait()
        oldRelease.open()
        let staleRejected: Bool
        switch await old.result { case .failure(let error): staleRejected = error is CancellationError; case .success: staleRejected = false }
        // An old completion must not clear the newer in-flight read.
        let joined = boundary.task(load: { boundaryCalls += 1; return 99 }, commit: { boundaryPublished.append($0) })
        newRelease.open()
        let freshValues = [try await fresh.value, try await joined.value]
        precondition(staleRejected && freshValues == [2,2] && boundaryCalls == 2 && boundaryPublished == [2], "A pre-write response must neither publish stale membership nor cancel/replace the newer read")
        let next = boundary.task(load: { boundaryCalls += 1; return 3 }, commit: { boundaryPublished.append($0) })
        let nextValue = try await next.value
        precondition(nextValue == 3 && boundaryCalls == 3 && boundaryPublished == [2,3], "A completed read must release its slot for a later forced refresh")
        precondition(OfflineQuota.downloadBudget(used: 6_000_000_000, limit: 5_000_000_000, free: 50_000_000_000) == 0, "Full offline quota must pause; never evict retained works")
        precondition(OfflineQuota.downloadBudget(used: 2_000_000_000, limit: 10_000_000_000, free: 4_000_000_000) == 3_000_000_000, "Download budget must preserve the free-space reserve")
        precondition(OfflineQuota.downloadBudget(used: 0, limit: 10_000_000_000, free: nil) == 0 && OfflineQuota.downloadBudget(used: 0, limit: 10_000_000_000, free: 500_000_000) == 0, "Unknown or low free space cannot start a download")
        let untrustedLocal = try decoder.decode(MediaItem.self, from: Data(#"{"id":5,"url":"https://example.com/a.png","type":"image","offlineMediaURL":"file:///etc/passwd","offlinePosterURL":"file:///etc/passwd"}"#.utf8))
        precondition(untrustedLocal.offlineMediaURL == nil && untrustedLocal.offlinePosterURL == nil && untrustedLocal.mediaURL?.scheme == "https", "Remote JSON must not create a local-file reference")
        var offlineRecord = OfflineRecord(id: 42, video: true, username: "fixture-author", creatorID: 7, browsingLevel: 1, collectionIDs: [10,11], cloudState: .saved)
        offlineRecord.fileState = .ready; offlineRecord.bytes = 1234
        let manifest = OfflineManifest(accountID: 7, records: [offlineRecord], omittedIDs: [99], lastScan: Date())
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestText = String(decoding: manifestData, as: UTF8.self).lowercased()
        precondition(!manifestText.contains("http") && !manifestText.contains("token") && !manifestText.contains("cookie") && !manifestText.contains("url"), "Offline index must not persist media URLs or authorization material")
        let restored = try decoder.decode(OfflineManifest.self, from: manifestData)
        precondition(restored.accountID == 7 && restored.records.count == 1 && restored.records[0].collectionIDs == [10,11] && restored.omittedIDs == [99], "Cold restore retains account scope, multi-folder membership and local removal exclusions")
        let local = restored.records[0].media(in: URL(fileURLWithPath: "/tmp/offline-fixture", isDirectory: true))
        precondition(local.mediaURL?.isFileURL == true && local.mediaURL?.lastPathComponent == "42.mp4" && local.url.isEmpty, "Offline playback uses a derived local path and does not reconstruct a remote URL")
        print("CoreChecks: invariant checks passed")
    }
}

@MainActor private final class ReadGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let continuations = waiters; waiters = []
        for continuation in continuations { continuation.resume() }
    }
}
