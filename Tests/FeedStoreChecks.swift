import Foundation

// Compile the production FeedStore with a deterministic read-only site double.
// No credentials or network are used; responses can finish out of order.
@MainActor final class FakeFeedSource: FeedPageReading {
    var feedIdentity = "fixture:1"
    var siteRetryAvailableAt: Date?
    struct Request { let filter: FeedFilter; let cursor: String?; let creatorID: Int?; let collectionID: Int?; let includeTags: Bool; let followed: Bool; let allAccessibleLevels: Bool; var searchID: String? = nil }
    var requests: [Request] = []
    var fetch: (Request) async throws -> MediaPage = { _ in .init(items: [], metadata: .init(nextCursor: nil)) }
    func mediaPage(filter: FeedFilter, cursor: String?, creator: Creator?, followed: Bool, includeTags: Bool) async throws -> MediaPage {
        let request = Request(filter: filter, cursor: cursor, creatorID: creator?.id, collectionID: nil, includeTags: includeTags, followed: followed, allAccessibleLevels: false)
        requests.append(request); return try await fetch(request)
    }
    func collectionPage(id: Int, filter: FeedFilter, cursor: String?, allAccessibleLevels: Bool, includeTags: Bool) async throws -> MediaPage {
        let request = Request(filter: filter, cursor: cursor, creatorID: nil, collectionID: id, includeTags: includeTags, followed: false, allAccessibleLevels: allAccessibleLevels)
        requests.append(request); return try await fetch(request)
    }
    func searchMediaPage(target: MediaSearchTarget, filter: FeedFilter, cursor: String?, includeTags: Bool) async throws -> MediaPage {
        let request = Request(filter: filter, cursor: cursor, creatorID: nil, collectionID: nil, includeTags: includeTags, followed: false, allAccessibleLevels: false, searchID: target.id)
        requests.append(request); return try await fetch(request)
    }
}

@MainActor private final class Gate {
    var continuation: CheckedContinuation<Void, Never>?
    var opened = false
    func wait() async { if !opened { await withCheckedContinuation { continuation = $0 } } }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

@main struct FeedStoreChecks {
    @MainActor static func main() async throws {
        var checkCount = 0
        func check(_ value: Bool, _ message: String = "") { Swift.precondition(value, message); checkCount += 1 }
        func page(_ id: Int? = nil, video: Bool = false, cursor: String? = nil) -> MediaPage {
            .init(items: id.map { [.init(id: $0, url: "https://example.com/fixture/\($0)", width: nil, height: nil, type: video ? "video" : "image", username: "fixture", browsingLevel: 1, thumbnail: nil)] } ?? [], metadata: .init(nextCursor: cursor))
        }
        var fixtureNow = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            let observed = TagObservationStore(), source = FakeFeedSource()
            let collected = FeedStore(observations: observed)
            let valid = (1...3).map { id in
                MediaItem(id: id, url: "https://fixture.invalid/observed/\(id)", width: 1, height: 1,
                          type: "image", username: "fixture", browsingLevel: 1, thumbnail: nil,
                          tags: [.init(id: 300, name: "sample")])
            }
            let invalid = MediaItem(id: 4, url: "", width: 1, height: 1, type: "image", username: "fixture",
                                    browsingLevel: 1, thumbnail: nil, tags: [.init(id: 301, name: "invalid")])
            source.fetch = { _ in .init(items: valid + [invalid], metadata: .init(nextCursor: nil)) }
            _ = await collected.activate(session: source, filter: .init(kind: .all), source: .discovery,
                                         blockedTags: ["blocked"], deduplicateMediaAssets: true)
            let policy = TagAvailabilityPolicy(blockedTags: ["blocked"], deduplicateMediaAssets: true)
            check(observed.estimate(tagID: 300, scope: source.tagEvidenceIdentity, policy: policy)?.countLowerBound == 3,
                  "Normal FeedStore pages contribute visible tag samples through the shared integration")
            check(observed.estimate(tagID: 301, scope: source.tagEvidenceIdentity, policy: policy) == nil,
                  "Rows rejected by the actual accumulator cannot become tag evidence")
            check(source.requests.count == 1, "Collecting evidence adds zero per-tag network reads")
            let limited = FeedStore(now: { fixtureNow })
            source.siteRetryAvailableAt = fixtureNow.addingTimeInterval(900)
            source.fetch = { _ in throw ClientError.http(429) }
            _ = await limited.activate(session: source, filter: .init(kind: .video), source: .discovery)
            check(limited.retryAvailableAt == source.siteRetryAvailableAt,
                  "Feed retries honor the shared server cooldown instead of a short local retry interval")
            let calls = source.requests.count
            _ = await limited.next(session: source)
            check(source.requests.count == calls, "Repeated explicit continuation cannot bypass the shared deadline")
        }
        let site = FakeFeedSource(), store = FeedStore(now: { fixtureNow })
        site.fetch = { _ in page(3) }
        let initial = await store.activate(session: site, filter: FeedFilter(kind: .image), source: .discovery)
        let requestCountAfterInitial = site.requests.count
        let same = await store.activate(session: site, filter: FeedFilter(kind: .image), source: .discovery)
        check(site.requests.count == requestCountAfterInitial && same.status == .unchanged && store.accepts(same, identity: site.feedIdentity),
              "A successfully loaded identical request key is not fetched twice")
        check(initial.didCommit && store.accepts(initial, identity: site.feedIdentity), "A caller can validate the exact committed request revision")
        site.requests = []
        site.fetch = { _ in page(4) }
        _ = await store.activate(session: site, filter: FeedFilter(kind: .image), source: .following)
        check(site.requests.last?.followed == true && site.requests.last?.creatorID == nil,
              "Following is an explicit source and cannot overlap creator or discovery arguments")
        site.requests = []
        _ = await store.activate(session: site, filter: FeedFilter(kind: .image), source: .creator(.init(id: 8, username: "fixture", image: nil)))
        check(site.requests.last?.creatorID == 8 && site.requests.last?.followed == false && site.requests.last?.collectionID == nil,
              "Creator source routes to only the creator request")
        site.requests = []
        _ = await store.activate(session: site, filter: FeedFilter(kind: .image), source: .collection(44))
        check(site.requests.last?.collectionID == 44 && site.requests.last?.creatorID == nil && site.requests.last?.followed == false && site.requests.last?.allAccessibleLevels == false,
              "Collection source carries only the collection identifier")
        site.requests = []
        _ = await store.activate(session: site, filter: FeedFilter(kind: .image), source: .search(.title("fixture")))
        check(site.requests.last?.searchID == "title:fixture" && site.requests.last?.collectionID == nil && site.requests.last?.creatorID == nil,
              "Search source cannot overlap creator, following, or collection origins")

        let oldStarted = Gate(), releaseOld = Gate()
        site.fetch = { request in
            if request.filter.kind == .video { oldStarted.open(); await releaseOld.wait(); return page(1, video: true, cursor: "stale") }
            return page(2)
        }
        let old = Task { await store.activate(session: site, filter: .defaults(for: .creator, kind: .video), source: .creator(.init(id: 1, username: "old", image: nil)), force: true) }
        await oldStarted.wait()
        _ = await store.activate(session: site, filter: .defaults(for: .creator, kind: .image), source: .creator(.init(id: 2, username: "new", image: nil)), force: true)
        releaseOld.open(); _ = await old.value
        check(store.items.map(\.id) == [2] && store.reachedEnd && !store.loading, "An old author/type request cannot restore stale rows, cursor or loading state")

        site.requests = []; let identityStarted = Gate(), releaseIdentity = Gate()
        site.fetch = { _ in identityStarted.open(); await releaseIdentity.wait(); return page(5) }
        let identityTask = Task { await store.activate(session: site, filter: FeedFilter(kind: .image), source: .discovery, force: true) }
        await identityStarted.wait(); site.feedIdentity = "fixture:2"; releaseIdentity.open()
        let identityCommit = await identityTask.value
        check(identityCommit.status == .superseded && store.items.isEmpty,
              "An account identity change invalidates an in-flight page before commit")
        site.feedIdentity = "fixture:1"

        site.requests = []; site.fetch = { _ in page(6) }
        let cancelled = Task { await store.activate(session: site, filter: FeedFilter(kind: .image), source: .discovery, force: true) }
        try? await Task.sleep(for: .milliseconds(10))
        cancelled.cancel()
        let cancelCommit = await cancelled.value
        try? await Task.sleep(for: .milliseconds(280))
        check(cancelCommit.status == .cancelled && site.requests.isEmpty,
              "Cancellation after entering source-switch debounce does not submit late")
        let resumed = await store.activate(session: site, filter: FeedFilter(kind: .image), source: .discovery)
        check(resumed.status == .committed && store.items.map(\.id) == [6],
              "An uncompleted cancelled activation can continue on the same key")
        let cancelledBeforeEntry = Task {
            await Task.yield()
            return await store.activate(session: site, filter: FeedFilter(kind: .video), source: .following, force: true)
        }
        cancelledBeforeEntry.cancel()
        let earlyCancelCommit = await cancelledBeforeEntry.value
        check(earlyCancelCommit.status == .cancelled && store.items.map(\.id) == [6]
              && store.accepts(resumed, identity: site.feedIdentity),
              "A cancelled activation rejected at entry cannot clear a newer committed result")

        site.requests = []; site.fetch = { _ in page(7) }
        let debounced = Task { await store.activate(session: site, filter: FeedFilter(kind: .image), source: .discovery, force: true) }
        try? await Task.sleep(for: .milliseconds(10))
        let coalesced = await store.activate(session: site, filter: FeedFilter(kind: .image), source: .discovery)
        let displacedOwner = await debounced.value
        check(coalesced.status == .committed && displacedOwner.status == .superseded && site.requests.count == 1,
              "A same-key activation takes over pending debounce ownership without duplicate requests")
        check(site.requests.count == 1 && store.items.map(\.id) == [7],
              "Concurrent same-key activation results in one request only")

        site.requests = []; site.fetch = { _ in page(9) }
        let cancelledOwner = Task { await store.activate(session: site, filter: FeedFilter(kind: .image), source: .discovery, force: true) }
        try? await Task.sleep(for: .milliseconds(10))
        cancelledOwner.cancel()
        let replacementOwner = await store.activate(session: site, filter: FeedFilter(kind: .image), source: .discovery)
        let replacedCommit = await cancelledOwner.value
        check(replacedCommit.status == .cancelled && replacementOwner.status == .committed
              && site.requests.count == 1 && store.items.map(\.id) == [9],
              "A same-key caller takes over when the debounce owner is cancelled")

        let flightStore = FeedStore(), flightStarted = Gate(), releaseFlight = Gate()
        site.requests = []; var flightCalls = 0
        site.fetch = { _ in
            flightCalls += 1
            if flightCalls == 1 {
                flightStarted.open(); await releaseFlight.wait()
                if Task.isCancelled { throw CancellationError() }
                return page(10)
            }
            return page(11)
        }
        let flightOwner = Task {
            await flightStore.activate(session: site, filter: FeedFilter(kind: .image), source: .discovery, force: true)
        }
        await flightStarted.wait()
        let inFlightJoin = await flightStore.activate(session: site, filter: FeedFilter(kind: .image), source: .discovery)
        check(inFlightJoin.status == .unchanged && site.requests.count == 1,
              "An uncancelled same-key in-flight request is joined without a duplicate RPC")
        flightOwner.cancel()
        let flightSuccessor = await flightStore.activate(session: site, filter: FeedFilter(kind: .image), source: .discovery)
        check(flightSuccessor.status == .committed && flightStore.items.map(\.id) == [11] && site.requests.count == 2,
              "A same-key activation takes over an in-flight page after its owner is cancelled")
        releaseFlight.open()
        let flightCancelled = await flightOwner.value
        let flightState = await flightStore.activate(session: site, filter: FeedFilter(kind: .image), source: .discovery)
        check(flightCancelled.status == .cancelled && flightState.state == .ended
              && flightStore.items.map(\.id) == [11] && flightStore.accepts(flightSuccessor, identity: site.feedIdentity),
              "A late cancelled in-flight owner cannot overwrite its successor")

        let cancellationStore = FeedStore(), lateStarted = Gate(), releaseLate = Gate()
        site.requests = []
        site.fetch = { request in
            if request.filter.kind == .video {
                lateStarted.open(); await releaseLate.wait()
                throw CancellationError()
            }
            return page(8)
        }
        let lateCancelled = Task {
            await cancellationStore.activate(session: site, filter: FeedFilter(kind: .video), source: .discovery, force: true)
        }
        await lateStarted.wait(); lateCancelled.cancel()
        let newerCommit = await cancellationStore.activate(session: site, filter: FeedFilter(kind: .image), source: .discovery, force: true)
        check(newerCommit.status == .committed && newerCommit.state == .ended && cancellationStore.items.map(\.id) == [8],
              "A newer request can finish while an older cancelled response is still pending")
        releaseLate.open()
        let lateCommit = await lateCancelled.value
        let afterLateCancellation = await cancellationStore.activate(session: site, filter: FeedFilter(kind: .image), source: .discovery)
        check(lateCommit.status == .cancelled && afterLateCancellation.state == .ended && cancellationStore.items.map(\.id) == [8],
              "A late cancellation cannot overwrite the newer completed request state")

        site.requests = []; var calls = 0
        site.fetch = { _ in calls += 1; return calls <= 4 ? page(100 + calls, cursor: "next:\(calls)") : page(9, video: true) }
        _ = await store.activate(session: site, filter: .defaults(for: .creator, kind: .video), source: .discovery, force: true)
        check(store.items.map(\.id) == [9] && store.reachedEnd && site.requests.map(\.cursor) == [nil,"next:1","next:2","next:3","next:4"],
              "One load automatically crosses its four-page scheduling slice and finds the fifth matching page")
        check(store.continuationState == .ended && !store.loading, "Only the explicit server end marks the filtered scan ended")

        site.requests = []; site.fetch = { _ in page(10, cursor: "old-filter-cursor") }
        _ = await store.activate(session: site, filter: FeedFilter(kind: .image, period: "Week"), source: .creator(.init(id: 1, username: "old", image: nil)), force: true)
        site.fetch = { _ in page(11) }
        _ = await store.activate(session: site, filter: .defaults(for: .creator, kind: .image), source: .creator(.init(id: 2, username: "new", image: nil)), force: true)
        check(site.requests.last?.cursor == nil && site.requests.last?.creatorID == 2 && store.items.map(\.id) == [11], "Changed author or filters start from a fresh cursor and replace the old result set")

        var fail = true; site.requests = []
        site.fetch = { _ in if fail { throw URLError(.timedOut) }; return page(12) }
        _ = await store.activate(session: site, filter: .defaults(for: .creator, kind: .image), source: .discovery, force: true)
        check(store.error != nil && !store.reachedEnd && store.items.isEmpty, "A request failure must remain an error, not an empty-author success")
        let failedRequestCount = site.requests.count
        let failedAgain = await store.activate(session: site, filter: .defaults(for: .creator, kind: .image), source: .discovery)
        check(failedAgain.status == .unchanged && site.requests.count == failedRequestCount,
              "An identical failed key is not silently reloaded by activation")
        fail = false; fixtureNow = fixtureNow.addingTimeInterval(1); _ = await store.next(session: site)
        check(store.error == nil && store.items.map(\.id) == [12] && site.requests.last?.cursor == nil, "Retry preserves the original request position and clears the error only on success")
        func video(_ id: Int, _ asset: String, tags: [MediaTag]? = nil) -> MediaItem {
            .init(id: id, url: "https://image.civitai.com/token/\(asset)/width=720/clip.mp4", width: nil, height: nil, type: "video", username: "fixture", browsingLevel: 1, thumbnail: nil, tags: tags)
        }
        let assetA = "1B8CB1F8-AC2B-4E7D-93D0-0D2BF22F3BA1", assetB = "2B8CB1F8-AC2B-4E7D-93D0-0D2BF22F3BA1"
        var pages = [MediaPage(items: [video(20,assetA),video(21,assetA)], metadata: .init(nextCursor: "overlap")), MediaPage(items: [video(20,assetA),video(22,assetB)], metadata: .init(nextCursor: nil))]
        site.fetch = { _ in pages.removeFirst() }
        _ = await store.activate(session: site, filter: FeedFilter(kind: .video), source: .discovery, deduplicateMediaAssets: true, force: true)
        check(store.items.map(\.id) == [20] && store.duplicatesDiscarded == 1, "Same asset under different media IDs appears once in a timeline")
        _ = await store.next(session: site)
        check(store.items.map(\.id) == [20,22] && store.duplicatesDiscarded == 2, "Page overlaps dedupe IDs while new assets remain")
        site.fetch = { _ in .init(items: [video(20,assetA)], metadata: .init(nextCursor: nil)) }
        _ = await store.activate(session: site, filter: FeedFilter(kind: .video), source: .discovery, deduplicateMediaAssets: true, force: true)
        check(store.items.map(\.id) == [20], "Refresh starts a fresh seen-set and may show the same asset again")
        let imageURL = "https://image.civitai.com/token/\(assetA)/width=720/fixture.webp"
        let imageAliasURL = imageURL.replacingOccurrences(of: "width=720", with: "width=1080")
        site.fetch = { request in
            if request.cursor == nil {
                return .init(items: [.init(id: 24, url: imageURL, width: nil, height: nil, type: nil, username: "fixture", browsingLevel: 1, thumbnail: nil)], metadata: .init(nextCursor: "image-alias"))
            }
            return .init(items: [.init(id: 25, url: imageAliasURL, width: nil, height: nil, type: "image", username: "fixture", browsingLevel: 1, thumbnail: nil)], metadata: .init(nextCursor: nil))
        }
        _ = await store.activate(session: site, filter: FeedFilter(kind: .image), source: .discovery, deduplicateMediaAssets: true, force: true)
        _ = await store.next(session: site)
        check(store.items.map(\.id) == [24] && store.duplicatesDiscarded == 1,
              "FeedStore deduplicates a missing-type image against a later explicit-image quality variant")
        site.fetch = { _ in .init(items: [video(20,assetA)], metadata: .init(nextCursor: nil)) }
        let following = FeedStore()
        _ = await following.activate(session: site, filter: FeedFilter(kind: .video), source: .following, deduplicateMediaAssets: true, force: true)
        check(following.items.map(\.id) == [20] && site.requests.last?.followed == true, "Following and recommendation seen-sets remain independent")
        site.fetch = { _ in .init(items: [video(20,assetA),video(21,assetA)], metadata: .init(nextCursor: nil)) }
        _ = await store.activate(session: site, filter: FeedFilter(kind: .video), source: .discovery, force: true)
        check(store.items.count == 1, "Work/collection grids use the same default media identity policy as timelines")
        _ = await store.activate(session: site, filter: FeedFilter(kind: .video), source: .discovery, deduplicateMediaAssets: false, force: true)
        check(store.items.count == 2, "Turning off media merging reveals each original work record without changing cloud relations")
        var variant = video(23,assetA.lowercased()); variant = .init(id: variant.id, url: variant.url.replacingOccurrences(of: "width=720", with: "width=1080"), width: nil, height: nil, type: "video", username: "fixture", browsingLevel: 1, thumbnail: nil)
        check(variant.mediaAssetKey == video(20,assetA).mediaAssetKey && video(20,assetA).mediaAssetKey != video(22,assetB).mediaAssetKey,
              "Typed Civitai media identity ignores quality variants but preserves distinct UUIDs")

        site.requests = []; calls = 0
        site.fetch = { _ in
            calls += 1
            let tags: [MediaTag]? = calls <= 3 ? [.init(name: " FuTa ")] : (calls == 4 ? nil : [.init(name: "landscape")])
            return .init(items: [video(30 + calls, calls <= 4 ? assetA : assetB, tags: tags)], metadata: .init(nextCursor: calls <= 4 ? "tag:\(calls)" : nil))
        }
        _ = await store.activate(session: site, filter: FeedFilter(kind: .video), source: .discovery, blockedTags: ["futa"], force: true)
        check(store.items.map(\.id) == [35] && store.hiddenByTags == 3 && store.unverifiedTags == 1 && site.requests.allSatisfy(\.includeTags), "Blocked and unknown-only batches automatically continue with actual tag metadata")
        check(store.items.map(\.id) == [35] && store.reachedEnd && site.requests.last?.cursor == "tag:4", "Later allowed work remains reachable beyond four hidden pages")
        site.fetch = { _ in .init(items: [video(40,assetA,tags: [.init(name: "landscape")])], metadata: .init(nextCursor: nil)) }
        _ = await store.activate(session: site, filter: FeedFilter(kind: .video), source: .collection(7), blockedTags: ["futa"], force: true)
        check(site.requests.last?.collectionID == 7 && site.requests.last?.includeTags == true && store.items.map(\.id) == [40], "Collections use the same tag policy without dropping ownership context")
        site.requests = []; site.fetch = { _ in page(cursor: "repeat") }
        _ = await store.activate(session: site, filter: FeedFilter(), source: .discovery, force: true)
        check(site.requests.count == 2 && store.error != nil && !store.reachedEnd, "Cursor loop is bounded and reported as an error rather than empty completion")

        let restartStore = FeedStore()
        site.requests = []; site.fetch = { _ in page(201, cursor: "prior-tail") }
        _ = await restartStore.activate(session: site, filter: FeedFilter(kind: .image), source: .discovery, force: true)
        let priorRows = restartStore.items
        site.requests = []; site.fetch = { request in
            check(request.cursor == nil, "From-start restart always requests cursor nil")
            return page(202, cursor: "fresh-tail")
        }
        let restartSuccess = await restartStore.restartFromStart(session: site, filter: FeedFilter(kind: .image), source: .discovery)
        check(restartSuccess.status == .committed && restartStore.items.map(\.id) == [202]
              && restartStore.items != priorRows && !restartStore.reachedEnd && site.requests.count == 1,
              "A successful restart atomically replaces prior rows with the first fresh page")

        let failedRestartStore = FeedStore()
        site.requests = []; site.fetch = { _ in page(211, cursor: "retained-tail") }
        _ = await failedRestartStore.activate(session: site, filter: FeedFilter(kind: .image), source: .discovery, force: true)
        let beforeFailureItems = failedRestartStore.items
        site.fetch = { _ in throw URLError(.timedOut) }
        let failedRestart = await failedRestartStore.restartFromStart(session: site, filter: FeedFilter(kind: .image), source: .discovery)
        check(failedRestart.status == .failedRetainingPrevious && failedRestart.error != nil
              && failedRestartStore.items == beforeFailureItems && failedRestartStore.error == nil,
              "A failed restart reports its error without mutating the prior list or ordinary load error")
        site.fetch = { request in check(request.cursor == "retained-tail", "Failure rollback preserves the exact old continuation cursor"); return page(212) }
        let continuationAfterRollback = await failedRestartStore.next(session: site)
        check(continuationAfterRollback.status == .committed && failedRestartStore.items.map(\.id) == [211,212],
              "The retained feed can continue normally after a failed restart")

        let coalescedRestartStore = FeedStore(), restartStarted = Gate(), releaseRestart = Gate()
        site.requests = []; site.fetch = { _ in restartStarted.open(); await releaseRestart.wait(); return page(221) }
        let firstRestartCaller = Task {
            await coalescedRestartStore.restartFromStart(session: site, filter: FeedFilter(kind: .image), source: .discovery)
        }
        await restartStarted.wait()
        let secondRestartCaller = Task {
            await coalescedRestartStore.restartFromStart(session: site, filter: FeedFilter(kind: .image), source: .discovery)
        }
        await Task.yield()
        secondRestartCaller.cancel()
        check(site.requests.count == 1, "Repeated same-key restart joins one in-flight request")
        releaseRestart.open()
        let firstRestartResult = await firstRestartCaller.value
        let secondRestartResult = await secondRestartCaller.value
        check(firstRestartResult.status == .committed && secondRestartResult.status == .committed
              && coalescedRestartStore.items.map(\.id) == [221],
              "Cancelling a same-key joining caller does not cancel the original restart owner")

        let staleRestartStore = FeedStore(), oldPageStarted = Gate(), releaseOldPage = Gate()
        var stalePageObservedCancellation = false
        site.requests = []; site.fetch = { request in
            if request.cursor == "old-next" {
                oldPageStarted.open(); await releaseOldPage.wait()
                stalePageObservedCancellation = Task.isCancelled
                return page(231, cursor: "stale-tail")
            }
            if request.cursor == nil { return page(232, cursor: "new-tail") }
            return page(230, cursor: "old-next")
        }
        let staleSeed = MediaItem(id: 230, url: "https://example.com/fixture/230", width: nil, height: nil,
                                  type: "image", username: "fixture", browsingLevel: 1, thumbnail: nil)
        staleRestartStore.restoreTimeline(items: [staleSeed], identity: site.feedIdentity, filter: FeedFilter(kind: .image), followed: false,
                                          continuation: TimelineContinuation(cursor: "old-next", capturedAt: Date(), reachedEnd: false), blockedTags: [])
        let staleNext = Task { await staleRestartStore.next(session: site) }
        await oldPageStarted.wait()
        let freshRestart = await staleRestartStore.restartFromStart(session: site, filter: FeedFilter(kind: .image), source: .discovery)
        releaseOldPage.open(); _ = await staleNext.value
        check(freshRestart.status == .committed && staleRestartStore.items.map(\.id) == [232]
              && staleRestartStore.requestKey?.filter == FeedFilter(kind: .image) && stalePageObservedCancellation,
              "Restart cancels the in-flight old page and rejects its late response")

        let supersedeRestartStore = FeedStore(), supersededStarted = Gate(), releaseSuperseded = Gate()
        site.requests = []; site.fetch = { request in
            if request.filter.kind == .image { supersededStarted.open(); await releaseSuperseded.wait(); return page(241) }
            return page(242, video: true)
        }
        let supersededRestartTask = Task {
            await supersedeRestartStore.restartFromStart(session: site, filter: FeedFilter(kind: .image), source: .discovery)
        }
        await supersededStarted.wait()
        let replacement = await supersedeRestartStore.activate(session: site, filter: FeedFilter(kind: .video), source: .discovery, force: true)
        releaseSuperseded.open()
        let supersededRestart = await supersededRestartTask.value
        check(replacement.status == .committed && supersededRestart.status == .cancelled
              && supersedeRestartStore.items.map(\.id) == [242],
              "A changed filter cancels and supersedes the active restart without stale commit")

        let identityRestartStore = FeedStore(), identityStartedForRestart = Gate(), releaseIdentityRestart = Gate()
        site.feedIdentity = "fixture:1"
        site.fetch = { _ in identityStartedForRestart.open(); await releaseIdentityRestart.wait(); return page(243) }
        let identityRestartTask = Task {
            await identityRestartStore.restartFromStart(session: site, filter: FeedFilter(kind: .image), source: .discovery)
        }
        await identityStartedForRestart.wait()
        site.feedIdentity = "fixture:2"
        releaseIdentityRestart.open()
        let identityRestartResult = await identityRestartTask.value
        check(identityRestartResult.status == .superseded && identityRestartStore.items.isEmpty
              && identityRestartStore.requestKey == nil,
              "An account identity change invalidates an in-flight restart without relabeling old rows")
        site.feedIdentity = "fixture:1"

        let filteredRestartStore = FeedStore()
        site.requests = []; site.fetch = { request in
            switch request.cursor {
            case nil: return .init(items: [], metadata: .init(nextCursor: "empty-one"))
            case "empty-one": return .init(items: [], metadata: .init(nextCursor: "empty-two"))
            default: return page(251, video: true)
            }
        }
        let emptyPageRestart = await filteredRestartStore.restartFromStart(session: site, filter: FeedFilter(kind: .video), source: .discovery)
        check(emptyPageRestart.status == .committed && filteredRestartStore.items.map(\.id) == [251]
              && site.requests.map(\.cursor) == [nil, "empty-one", "empty-two"],
              "Empty filtered pages advance their opaque cursor until the first visible result")

        let restoredSeedStore = FeedStore()
        let seedItem = video(261, assetA)
        site.fetch = { _ in .init(items: [seedItem], metadata: .init(nextCursor: nil)) }
        _ = await restoredSeedStore.activate(session: site, filter: FeedFilter(kind: .video), source: .discovery,
                                             deduplicateMediaAssets: false, force: true)
        restoredSeedStore.restoreTimeline(items: [seedItem], identity: site.feedIdentity, filter: FeedFilter(kind: .video), followed: false,
                                          continuation: nil, blockedTags: [])
        var freshVariant = video(262, assetA)
        freshVariant = .init(id: freshVariant.id, url: freshVariant.url.replacingOccurrences(of: "width=720", with: "width=1080"),
                             width: nil, height: nil, type: "video", username: "fixture", browsingLevel: 1, thumbnail: nil)
        site.fetch = { _ in .init(items: [freshVariant], metadata: .init(nextCursor: nil)) }
        let cleanQueueRestart = await restoredSeedStore.restartFromStart(session: site, filter: FeedFilter(kind: .video), source: .discovery)
        check(cleanQueueRestart.status == .committed && restoredSeedStore.items.map(\.id) == [262],
              "A restart builds a fresh accumulator without restore-time rescan exclusions")

        let liveTagStore = FeedStore(), liveTagStarted = Gate(), releaseLiveTag = Gate()
        site.fetch = { _ in
            liveTagStarted.open(); await releaseLiveTag.wait()
            return .init(items: [video(271, assetA, tags: [.init(name: "city")]), video(272, assetB, tags: [.init(name: "nature")])],
                         metadata: .init(nextCursor: nil))
        }
        let liveTagTask = Task {
            await liveTagStore.restartFromStart(session: site, filter: FeedFilter(kind: .video), source: .discovery, blockedTags: [])
        }
        await liveTagStarted.wait(); liveTagStore.applyBlockedTags(["city"]); releaseLiveTag.open()
        let liveTagRestart = await liveTagTask.value
        check(liveTagRestart.status == .committed && liveTagStore.items.map(\.id) == [272],
              "A tag block changed during the pending restart filters the staged first page")

        let liveTagUndoStore = FeedStore(), liveTagUndoStarted = Gate(), releaseLiveTagUndo = Gate()
        site.fetch = { _ in
            liveTagUndoStarted.open(); await releaseLiveTagUndo.wait()
            return .init(items: [video(281, assetA, tags: [.init(name: "city")]), video(282, assetB, tags: [.init(name: "nature")])],
                         metadata: .init(nextCursor: nil))
        }
        let liveTagUndoTask = Task {
            await liveTagUndoStore.restartFromStart(session: site, filter: FeedFilter(kind: .video), source: .discovery, blockedTags: ["city"])
        }
        await liveTagUndoStarted.wait(); liveTagUndoStore.applyBlockedTags([]); releaseLiveTagUndo.open()
        let liveTagUndoRestart = await liveTagUndoTask.value
        check(liveTagUndoRestart.status == .committed && liveTagUndoStore.items.map(\.id) == [281,282],
              "Undoing a tag block during the pending restart restores matching staged works")

        let liveAuthorSuite = "FeedRestartAuthorFixture.\(UUID().uuidString)"
        let liveAuthorDefaults = UserDefaults(suiteName: liveAuthorSuite)!
        defer { liveAuthorDefaults.removePersistentDomain(forName: liveAuthorSuite) }
        let liveAuthorBlocks = AuthorBlocklist(defaults: liveAuthorDefaults, key: "fixture.authorBlocks")
        let liveAuthorStore = FeedStore(authorBlocks: liveAuthorBlocks)
        let liveAuthorStarted = Gate(), releaseLiveAuthor = Gate()
        site.fetch = { _ in
            liveAuthorStarted.open(); await releaseLiveAuthor.wait()
            return .init(items: [
                .init(id: 291, url: "https://example.invalid/291", width: nil, height: nil, type: "image", username: "one", browsingLevel: 1, thumbnail: nil, creatorID: 91),
                .init(id: 292, url: "https://example.invalid/292", width: nil, height: nil, type: "image", username: "two", browsingLevel: 1, thumbnail: nil, creatorID: 92)
            ], metadata: .init(nextCursor: nil))
        }
        let liveAuthorTask = Task {
            await liveAuthorStore.restartFromStart(session: site, filter: FeedFilter(kind: .image), source: .discovery)
        }
        await liveAuthorStarted.wait()
        _ = liveAuthorBlocks.add(Creator(id: 91, username: "one", image: nil))
        releaseLiveAuthor.open()
        let liveAuthorRestart = await liveAuthorTask.value
        check(liveAuthorRestart.status == .committed && liveAuthorStore.items.map(\.id) == [292]
              && liveAuthorStore.hiddenByAuthors == 1,
              "A newly blocked author is read at restart commit, even before its observer task runs")

        let livePolicySuite = "FeedRestartAssetPolicy.\(UUID().uuidString)"
        let livePolicyDefaults = UserDefaults(suiteName: livePolicySuite)!
        defer { livePolicyDefaults.removePersistentDomain(forName: livePolicySuite) }
        livePolicyDefaults.set(false, forKey: "deduplicateMedia")
        let livePolicyStore = FeedStore(preferences: livePolicyDefaults)
        let livePolicyStarted = Gate(), releaseLivePolicy = Gate()
        site.fetch = { _ in
            livePolicyStarted.open(); await releaseLivePolicy.wait()
            return .init(items: [video(301, assetA), video(302, assetA)], metadata: .init(nextCursor: nil))
        }
        let livePolicyTask = Task {
            await livePolicyStore.restartFromStart(session: site, filter: FeedFilter(kind: .video), source: .discovery)
        }
        await livePolicyStarted.wait(); livePolicyDefaults.set(true, forKey: "deduplicateMedia"); releaseLivePolicy.open()
        let livePolicyRestart = await livePolicyTask.value
        check(livePolicyRestart.status == .committed && livePolicyStore.items.map(\.id) == [301]
              && livePolicyStore.duplicatesDiscarded == 1,
              "The latest asset deduplication preference is applied before staged restart commit")

        let fourHiddenStore = FeedStore()
        var hiddenPage = 0
        site.requests = []; site.fetch = { request in
            check(request.cursor == (hiddenPage == 0 ? nil : "hidden:\(hiddenPage)"), "Filtered restart advances its opaque cursor")
            hiddenPage += 1
            if hiddenPage == 10 {
                return .init(items: [video(320, assetB, tags: [.init(name: "nature")])], metadata: .init(nextCursor: nil))
            }
            return .init(items: [video(310 + hiddenPage, assetA + "-\(hiddenPage)", tags: [.init(name: "hidden")])],
                         metadata: .init(nextCursor: "hidden:\(hiddenPage)"))
        }
        let fourHiddenRestart = await fourHiddenStore.restartFromStart(session: site, filter: FeedFilter(kind: .video), source: .discovery,
                                                                        blockedTags: ["hidden"])
        check(fourHiddenRestart.status == .committed && fourHiddenStore.items.map(\.id) == [320] && fourHiddenStore.reachedEnd
              && site.requests.count == 10,
              "A staged restart crosses two hidden slices and commits only its first matching result or confirmed end")

        let start = Gate(), release = Gate()
        site.requests = []; site.fetch = { _ in start.open(); await release.wait(); return page(50) }
        let pending = Task { await store.activate(session: site, filter: FeedFilter(), source: .discovery, force: true) }
        await start.wait(); _ = await store.next(session: site)
        check(site.requests.count == 1, "Concurrent prefetch and load-more cannot issue duplicate page requests")
        release.open(); _ = await pending.value
        check(store.items.map(\.id) == [50] && !store.loading, "The single pending request completes normally")
        site.fetch = { _ in .init(items: [video(60,assetA,tags: [.init(name: "city")]),video(61,assetB,tags: [.init(name: "nature")])], metadata: .init(nextCursor: "unchanged-position")) }
        _ = await store.activate(session: site, filter: FeedFilter(kind: .video), source: .discovery, force: true)
        let requestCount = site.requests.count
        store.applyBlockedTags(["city"])
        check(store.items.map(\.id) == [61] && !store.reachedEnd && store.hiddenByTags == 1 && site.requests.count == requestCount, "Blocking loaded tags reconciles in place without reset/network")
        store.applyBlockedTags([])
        check(store.items.map(\.id) == [60,61] && !store.reachedEnd, "Undo restores loaded works and continuation")
        site.fetch = { request in check(request.cursor == "unchanged-position");return page(62,video:true) }
        _ = await store.next(session: site)
        check(store.items.map(\.id) == [60,61,62] && store.reachedEnd, "Tag changes preserve exact media cursor for next page")
        site.requests = []; site.fetch = { _ in page(70,video:true,cursor:"old-search") }
        _ = await store.activate(session: site, filter: FeedFilter(kind:.video), source: .search(.title("Old")), force: true)
        site.fetch = { _ in page(71) }
        _ = await store.activate(session: site, filter: FeedFilter(kind:.image), source: .search(.tag(.init(id:7,name:"city"))), force: true)
        check(site.requests.last?.searchID == "tag:7" && site.requests.last?.cursor == nil && store.items.map(\.id)==[71], "Search field/keyword/type changes replace results and cannot inherit a stale cursor")
        let beforeClear = site.requests.count; store.clear(); _ = await store.next(session: site)
        check(site.requests.count == beforeClear && store.items.isEmpty, "During immediate-filter debounce, cleared store cannot refetch the previous search/filter context")
        site.fetch={_ in .init(items:[video(80,assetA,tags:[.init(name:"city")]),video(81,assetB,tags:[.init(name:"nature")])],metadata:.init(nextCursor:"held"))}
        _ = await store.activate(session:site,filter:FeedFilter(kind:.video),source:.discovery,force:true);store.setTagPolicyDeferred(true);store.applyBlockedTags(["city"])
        check(store.items.map(\.id)==[80,81],"An open detail defers only its own list's visibility changes")
        let nestedSearch=FeedStore();_ = await nestedSearch.activate(session:site,filter:FeedFilter(kind:.video),source:.search(.tag(.init(id:1,name:"city"))),blockedTags:["city"],force:true)
        check(nestedSearch.items.map(\.id)==[81],"A search opened from details immediately respects newly persisted blocking")
        store.setTagPolicyDeferred(false)
        check(store.items.map(\.id)==[81] && !store.reachedEnd,"Closing details applies pending filtering while retaining cursor")
        store.setTagPolicyDeferred(true);store.applyBlockedTags([]);store.applyBlockedTags(["city"]);store.setTagPolicyDeferred(false)
        check(store.items.map(\.id)==[81],"Block/undo/reblock while detail is open commits the last intended policy once")

        let seed = video(90, assetA)
        let liveContinuation = TimelineContinuation(cursor: "restore-cursor", capturedAt: Date(), reachedEnd: false)!
        let restoreStore = FeedStore()
        restoreStore.restoreTimeline(items: [seed], identity: site.feedIdentity, filter: FeedFilter(kind: .video), followed: false,
                                     continuation: liveContinuation, blockedTags: [])
        site.requests = []; site.fetch = { _ in throw URLError(.timedOut) }
        let restoreCommit = await restoreStore.next(session: site)
        check(restoreCommit.status == .committed && restoreStore.accepts(restoreCommit, identity: site.feedIdentity),
              "A restored continuation carries its explicit identity through the next-page commit")
        check(restoreStore.items.map(\.id) == [90] && restoreStore.error != nil && site.requests.last?.cursor == "restore-cursor",
              "Failed continuation keeps the atomically restored rows and cursor position")
        restoreStore.restartContinuation()
        site.fetch = { request in
            check(request.cursor == nil, "Explicit fallback re-fetch starts at the upstream beginning")
            return .init(items: [seed, video(91, assetB)], metadata: .init(nextCursor: "new-tail"))
        }
        _ = await restoreStore.next(session: site)
        check(restoreStore.items.map(\.id) == [90,91] && !restoreStore.reachedEnd,
              "Restarting from the beginning seeds seen work IDs and adds later works without duplicating the restored row")
        check(restoreStore.continuationSnapshot(windowIDs: [90]) == nil && restoreStore.continuationSnapshot(windowIDs: [90,91])?.cursor == "new-tail",
              "Only a checkpoint window containing the actual accumulated tail may carry its cursor")

        let restorePolicyItems = [video(301, assetA), video(302, assetA)]
        let defaultSuite = "FeedRestoreDefault.\(UUID().uuidString)"
        let defaultDefaults = UserDefaults(suiteName: defaultSuite)!
        defer { defaultDefaults.removePersistentDomain(forName: defaultSuite) }
        let defaultRestoreStore = FeedStore(preferences: defaultDefaults)
        defaultRestoreStore.restoreTimeline(items: restorePolicyItems, identity: site.feedIdentity, filter: FeedFilter(kind: .video), followed: false,
                                            continuation: liveContinuation, blockedTags: [])
        check(defaultRestoreStore.items.map(\.id) == [301] && defaultRestoreStore.duplicatesDiscarded == 1,
              "A fresh timeline restore applies the default media asset deduplication policy")

        let overrideSuite = "FeedRestoreOverride.\(UUID().uuidString)"
        let overrideDefaults = UserDefaults(suiteName: overrideSuite)!
        defer { overrideDefaults.removePersistentDomain(forName: overrideSuite) }
        let overrideRestoreStore = FeedStore(preferences: overrideDefaults)
        site.fetch = { _ in .init(items: restorePolicyItems, metadata: .init(nextCursor: nil)) }
        _ = await overrideRestoreStore.activate(session: site, filter: FeedFilter(kind: .video), source: .discovery,
                                                deduplicateMediaAssets: false, force: true)
        overrideRestoreStore.restoreTimeline(items: restorePolicyItems, identity: site.feedIdentity, filter: FeedFilter(kind: .video), followed: false,
                                             continuation: liveContinuation, blockedTags: [])
        check(overrideRestoreStore.items.map(\.id) == [301,302] && overrideRestoreStore.duplicatesDiscarded == 0,
              "An explicit media deduplication override remains in force during restore")

        let changingSuite = "FeedRestoreChangingPreference.\(UUID().uuidString)"
        let changingDefaults = UserDefaults(suiteName: changingSuite)!
        defer { changingDefaults.removePersistentDomain(forName: changingSuite) }
        changingDefaults.set(false, forKey: "deduplicateMedia")
        let changingRestoreStore = FeedStore(preferences: changingDefaults)
        _ = await changingRestoreStore.activate(session: site, filter: FeedFilter(kind: .video), source: .discovery, force: true)
        changingDefaults.set(true, forKey: "deduplicateMedia")
        changingRestoreStore.restoreTimeline(items: restorePolicyItems, identity: site.feedIdentity, filter: FeedFilter(kind: .video), followed: false,
                                             continuation: liveContinuation, blockedTags: [])
        check(changingRestoreStore.items.map(\.id) == [301] && changingRestoreStore.duplicatesDiscarded == 1,
              "Restore reads the current preference when it changed after an earlier activation")

        let suite = "FeedStoreAuthorFixture.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suite)!
        defer { isolatedDefaults.removePersistentDomain(forName: suite) }
        let localBlocks = AuthorBlocklist(defaults: isolatedDefaults, key: "fixture.authorBlocks")
        check(localBlocks.add(Creator(id: 77, username: "Alice", image: nil)), "Feed author-filter fixture uses an isolated local blocklist")
        let authorStore = FeedStore(authorBlocks: localBlocks)
        site.fetch = { _ in
            .init(items: [
                .init(id: 100, url: "https://example.invalid/100", width: nil, height: nil, type: "image", username: "Other", browsingLevel: 1, thumbnail: nil, creatorID: 77),
                .init(id: 101, url: "https://example.invalid/101", width: nil, height: nil, type: "image", username: "ALICE", browsingLevel: 1, thumbnail: nil, creatorID: 88),
                .init(id: 102, url: "https://example.invalid/102", width: nil, height: nil, type: "image", username: " alice ", browsingLevel: 1, thumbnail: nil),
                .init(id: 103, url: "https://example.invalid/103", width: nil, height: nil, type: "image", username: nil, browsingLevel: 1, thumbnail: nil)
            ], metadata: .init(nextCursor: nil))
        }
        _ = await authorStore.activate(session: site, filter: FeedFilter(kind: .image), source: .discovery, force: true)
        check(authorStore.items.map(\.id) == [101,103] && authorStore.hiddenByAuthors == 2,
              "Injected author rules hide ID matches and unique anonymous handle matches but preserve a different known ID")
        check(localBlocks.add(Creator(id: 78, username: "ALICE", image: nil)), "Second author ID is retained independently even with the same username")
        await Task.yield()
        check(authorStore.items.map(\.id) == [101,102,103] && authorStore.hiddenByAuthors == 1,
              "Ambiguous duplicate handles stop matching while known IDs remain independent")
        localBlocks.remove(id: 77); await Task.yield()
        check(authorStore.items.map(\.id) == [100,101,103] && authorStore.hiddenByAuthors == 1,
              "Unblocking one ID restores its raw work while unique handle blocking remains accurate")
        site.fetch = { _ in
            .init(items: [.init(id: 104, url: "https://example.invalid/104", width: nil, height: nil, type: "image", username: "renamed", browsingLevel: 1, thumbnail: nil, creatorID: 78)], metadata: .init(nextCursor: nil))
        }
        _ = await authorStore.activate(session: site, filter: FeedFilter(kind: .image), source: .discovery, force: true)
        check(authorStore.items.isEmpty && authorStore.hiddenByAuthors == 1,
              "Every reload snapshots the currently injected blocked author IDs before fetching")
        // A scheduling slice is not a scan budget. Long filtered sequences
        // reach a real match/end without another user request or weaker filter.
        for matchingPage in [5, 9] {
            let source = FakeFeedSource()
            var slices: [Int] = []
            let scanning = FeedStore(slicePause: { slice in slices.append(slice); await Task.yield() })
            var index = 0
            let chosen = FeedFilter(kind: .video, sort: "Newest", period: "AllTime", onlyPG: true)
            source.fetch = { request in
                check(request.filter == chosen && request.cursor == (index == 0 ? nil : "scan:\(index)"),
                      "Every automatic batch preserves the exact condition and opaque cursor")
                index += 1
                return page(2_000 + index, video: index == matchingPage,
                            cursor: index == matchingPage ? nil : "scan:\(index)")
            }
            let result = await scanning.activate(session: source, filter: chosen, source: .discovery)
            check(result.didCommit && source.requests.count == matchingPage && scanning.items.map(\.id) == [2_000 + matchingPage],
                  "One owner finds a match on page\(matchingPage), beyond soft slices")
            check(slices.count == (matchingPage - 1) / 4 && scanning.continuationState == .ended,
                  "Cross-slice work yields through the bounded scheduler instead of reporting a false end")
        }
        let emptySource = FakeFeedSource(), allFiltered = FeedStore(slicePause: { _ in await Task.yield() })
        var emptyPage = 0
        emptySource.fetch = { _ in
            emptyPage += 1
            return page(3_000 + emptyPage, cursor: emptyPage == 33 ? nil : "filtered:\(emptyPage)")
        }
        _ = await allFiltered.activate(session: emptySource, filter: FeedFilter(kind: .video), source: .discovery)
        check(emptySource.requests.count == 33 && allFiltered.items.isEmpty && allFiltered.reachedEnd &&
              allFiltered.continuationState == .ended && allFiltered.error == nil,
              "Thirty-three filtered batches end only at the explicit server nil cursor")
        let requestsAtEnd = emptySource.requests.count
        _ = await allFiltered.nextAutomatically(session: emptySource)
        check(emptySource.requests.count == requestsAtEnd, "Confirmed end never auto-fetches a fabricated tail page")

        let durationSource = FakeFeedSource(), durationStore = FeedStore(slicePause: { _ in await Task.yield() })
        var durationPage = 0
        let durationFilter = FeedFilter(kind: .video, videoDurationRange: .init(minimumSeconds: 20, maximumSeconds: 30))
        durationSource.fetch = { request in
            check(request.filter == durationFilter, "Duration scanning never relaxes the chosen interval")
            durationPage += 1
            var item = video(4_000 + durationPage, "duration-\(durationPage)")
            if durationPage > 4 { item.metadata = .init(duration: durationPage == 9 ? 25 : 10) }
            return .init(items: [item], metadata: .init(nextCursor: durationPage == 9 ? nil : "duration:\(durationPage)"))
        }
        _ = await durationStore.activate(session: durationSource, filter: durationFilter, source: .discovery)
        check(durationStore.items.map(\.id) == [4_009] && durationStore.unverifiedDuration == 4 &&
              durationStore.hiddenByDuration == 4 && durationSource.requests.count == 9,
              "Unknown and mismatching durations are skipped across slices without admitting them to fill the feed")

        // Cancellation owns the inter-slice wait, not merely an HTTP task.
        let waitSource = FakeFeedSource(), waitStarted = Gate()
        let waitStore = FeedStore(slicePause: { _ in waitStarted.open(); try await Task.sleep(for: .seconds(5)) })
        var waitPage = 0
        waitSource.fetch = { _ in waitPage += 1; return page(5_000 + waitPage, cursor: "wait:\(waitPage)") }
        let waitOwner = Task { await waitStore.activate(session: waitSource, filter: FeedFilter(kind: .video), source: .discovery) }
        await waitStarted.wait()
        let waitRequestCount = waitSource.requests.count
        check(waitRequestCount == 4 && waitStore.continuationState == .scanning && waitStore.loading,
              "An empty slice remains visibly scanning under one owner")
        let cancelledAt = Date()
        waitOwner.cancel(); let waited = await waitOwner.value
        check(waited.status == .cancelled && Date().timeIntervalSince(cancelledAt) < 1 && waitSource.requests.count == waitRequestCount && !waitStore.loading,
              "Cancelling a slice wait terminates promptly and issues no next batch")
        waitSource.fetch = { request in check(request.cursor == "wait:4", "Cancelled scan retains its last committed cursor"); return page(5_100, video: true) }
        _ = await waitStore.nextAutomatically(session: waitSource)
        check(waitStore.items.map(\.id) == [5_100] && waitStore.reachedEnd,
              "A later valid owner can resume the cancelled slice without restarting the cursor")

        let switchSource = FakeFeedSource(), sliceStarted = Gate(), releaseSlice = Gate()
        let switchStore = FeedStore(slicePause: { _ in sliceStarted.open(); await releaseSlice.wait() })
        var oldBatches = 0
        switchSource.fetch = { request in
            if request.filter.kind == .image { return page(6_100) }
            oldBatches += 1; return page(6_000 + oldBatches, cursor: "old-slice:\(oldBatches)")
        }
        let oldSliceOwner = Task { await switchStore.activate(session: switchSource, filter: FeedFilter(kind: .video), source: .discovery) }
        await sliceStarted.wait()
        _ = await switchStore.activate(session: switchSource, filter: FeedFilter(kind: .image), source: .discovery, force: true)
        releaseSlice.open(); let oldSliceResult = await oldSliceOwner.value
        check(oldSliceResult.status != .committed && switchStore.items.map(\.id) == [6_100] && oldBatches == 4,
              "A filter switch invalidates a paused slice before it can request or commit another old batch")

        let identitySliceSource = FakeFeedSource(), identitySliceStarted = Gate(), releaseIdentitySlice = Gate()
        let identitySliceStore = FeedStore(slicePause: { _ in identitySliceStarted.open(); await releaseIdentitySlice.wait() })
        var identityBatches = 0
        identitySliceSource.fetch = { _ in identityBatches += 1; return page(6_200 + identityBatches, cursor: "identity-slice:\(identityBatches)") }
        let identitySliceOwner = Task { await identitySliceStore.activate(session: identitySliceSource, filter: FeedFilter(kind: .video), source: .discovery) }
        await identitySliceStarted.wait(); identitySliceSource.feedIdentity = "changed-between-slices"; releaseIdentitySlice.open()
        let identitySliceResult = await identitySliceOwner.value
        check(identitySliceResult.status == .superseded && identityBatches == 4 && identitySliceStore.items.isEmpty && !identitySliceStore.loading,
              "An account change during a wait stops the old owner before its next request")

        // Concurrent near-tail demand joins an uncancelled scanner, and the
        // previous media stays visible throughout many duplicate-only batches.
        let duplicateSource = FakeFeedSource(), duplicateStarted = Gate(), releaseDuplicate = Gate()
        let duplicateStore = FeedStore(slicePause: { _ in duplicateStarted.open(); await releaseDuplicate.wait() })
        let retainedMedia = video(7_000, assetA)
        duplicateStore.restoreTimeline(items: [retainedMedia], identity: duplicateSource.feedIdentity,
            filter: FeedFilter(kind: .video), followed: false,
            continuation: .init(cursor: "duplicate:0", capturedAt: Date(), reachedEnd: false), blockedTags: [])
        var duplicatePage = 0
        duplicateSource.fetch = { _ in
            duplicatePage += 1
            return .init(items: [video(7_000 + duplicatePage, duplicatePage == 9 ? assetB : assetA)],
                         metadata: .init(nextCursor: duplicatePage == 9 ? nil : "duplicate:\(duplicatePage)"))
        }
        let duplicateOwner = Task { await duplicateStore.nextAutomatically(session: duplicateSource) }
        await duplicateStarted.wait()
        let duplicateJoin = await duplicateStore.nextAutomatically(session: duplicateSource)
        check(duplicateJoin.status == .unchanged && duplicateSource.requests.count == 4 && duplicateStore.items == [retainedMedia],
              "A second near-tail trigger neither duplicates the scan nor removes currently visible media")
        releaseDuplicate.open(); _ = await duplicateOwner.value
        check(duplicateSource.requests.count == 9 && duplicateStore.items.map(\.id) == [7_000,7_009] && duplicateStore.duplicatesDiscarded == 8,
              "Duplicate-only batches cross slices and append only the later distinct asset")

        // Both immediate repeat and multi-cursor cycles are terminal protocol
        // failures for this cursor, while ordinary HTTP/network failures retry.
        for cyclic in [false, true] {
            let cycleSource = FakeFeedSource(), cycleStore = FeedStore(slicePause: { _ in await Task.yield() })
            cycleSource.fetch = { request in
                if request.cursor == nil { return page(cursor: "A") }
                if cyclic && request.cursor == "A" { return page(cursor: "B") }
                return page(cursor: "A")
            }
            _ = await cycleStore.activate(session: cycleSource, filter: FeedFilter(), source: .discovery)
            let cycleCount = cycleSource.requests.count
            check(cycleCount == (cyclic ? 3 : 2) && !cycleStore.reachedEnd && cycleStore.continuationState.requiresRestart,
                  "Repeated or cyclic cursor is stalled, never an exhausted feed")
            _ = await cycleStore.nextAutomatically(session: cycleSource); _ = await cycleStore.next(session: cycleSource)
            check(cycleSource.requests.count == cycleCount && !cycleStore.canRetryContinuation,
                  "Neither automatic nor ordinary continuation loops a stalled cursor")
            cycleSource.fetch = { request in check(request.cursor == nil, "Stall recovery is explicitly from the start"); return page(8_000) }
            let refreshed = await cycleStore.restartFromStart(session: cycleSource, filter: FeedFilter(), source: .discovery)
            check(refreshed.status == .committed && cycleStore.items.map(\.id) == [8_000], "Explicit refresh recovers a stalled protocol state")
        }
        for rateLimited in [false, true] {
            var clock = Date(timeIntervalSince1970: 2_000)
            let retrySource = FakeFeedSource(), retryStore = FeedStore(now: { clock })
            retrySource.fetch = { _ in if rateLimited { throw ClientError.http(429) }; throw URLError(.timedOut) }
            _ = await retryStore.activate(session: retrySource, filter: FeedFilter(kind: .video), source: .discovery)
            let failedCount = retrySource.requests.count
            check(failedCount == 1 && !retryStore.reachedEnd && retryStore.retryAvailableAt.map { $0 > clock } == true,
                  "A network or rate-limit error stops and exposes a bounded retry cooldown")
            _ = await retryStore.nextAutomatically(session: retrySource); _ = await retryStore.next(session: retrySource)
            check(retrySource.requests.count == failedCount, "A cooldown blocks repeated RPCs rather than spinning")
            clock = clock.addingTimeInterval(60)
            _ = await retryStore.nextAutomatically(session: retrySource)
            check(retrySource.requests.count == failedCount && retryStore.canRetryContinuation,
                  "An expired cooldown permits only explicit retry, never automatic error loops")
            retrySource.fetch = { request in check(request.cursor == nil, "Explicit retry preserves its failed cursor"); return page(8_100, video: true) }
            _ = await retryStore.next(session: retrySource)
            check(retryStore.items.map(\.id) == [8_100] && retryStore.error == nil && retryStore.continuationState == .ended,
                  "One explicit retry can complete the original request after cooldown")
        }

        let stagedSource = FakeFeedSource(), stagedStarted = Gate(), releaseStaged = Gate()
        let stagedStore = FeedStore(slicePause: { _ in stagedStarted.open(); await releaseStaged.wait() })
        stagedSource.fetch = { _ in page(9_000, video: true, cursor: "preserved-tail") }
        _ = await stagedStore.activate(session: stagedSource, filter: FeedFilter(kind: .video), source: .discovery)
        var stagedPage = 0
        stagedSource.requests = []
        stagedSource.fetch = { _ in
            stagedPage += 1
            return page(9_000 + stagedPage, video: stagedPage == 10, cursor: stagedPage == 10 ? nil : "restart-slice:\(stagedPage)")
        }
        let stagedOwner = Task { await stagedStore.restartFromStart(session: stagedSource, filter: FeedFilter(kind: .video), source: .discovery) }
        await stagedStarted.wait()
        let preservedTail = stagedStore.continuationSnapshot(windowIDs: [9_000])?.cursor
        check(stagedStore.items.map(\.id) == [9_000] && preservedTail == "preserved-tail" && stagedStore.continuationState == .scanning,
              "A multi-slice restart keeps the previous media and continuation until its first real result")
        let stagedJoin = await stagedStore.next(session: stagedSource)
        check(stagedJoin.status == .unchanged && stagedSource.requests.count == 4,
              "Ordinary continuation cannot create another owner during a staged restart")
        releaseStaged.open(); let stagedResult = await stagedOwner.value
        check(stagedResult.status == .committed && stagedPage == 10 && stagedStore.items.map(\.id) == [9_010],
              "A restart commits its tenth-batch match atomically, never a four-batch empty queue")

        let cancelledRestartSource = FakeFeedSource(), restartWaitStarted = Gate()
        let cancelledRestartStore = FeedStore(slicePause: { _ in restartWaitStarted.open(); try await Task.sleep(for: .seconds(5)) })
        cancelledRestartSource.fetch = { _ in page(9_100, video: true, cursor: "old-restart-tail") }
        _ = await cancelledRestartStore.activate(session: cancelledRestartSource, filter: FeedFilter(kind: .video), source: .discovery)
        var restartWaitPage = 0
        cancelledRestartSource.requests = []
        cancelledRestartSource.fetch = { _ in restartWaitPage += 1; return page(9_100 + restartWaitPage, cursor: "cancelled-restart:\(restartWaitPage)") }
        let restartWaitOwner = Task { await cancelledRestartStore.restartFromStart(session: cancelledRestartSource, filter: FeedFilter(kind: .video), source: .discovery) }
        await restartWaitStarted.wait(); cancelledRestartStore.invalidatePendingRequests()
        let cancelledRestartResult = await restartWaitOwner.value
        check(cancelledRestartResult.status == .cancelled && restartWaitPage == 4 && cancelledRestartStore.items.map(\.id) == [9_100],
              "Hiding or invalidating a restart cancels its slice wait and preserves the previous queue")

        let followSliceSource = FakeFeedSource(), followSliceStarted = Gate(), releaseFollowSlice = Gate()
        let followSliceStore = FeedStore(slicePause: { _ in followSliceStarted.open(); await releaseFollowSlice.wait() })
        var followSlicePage = 0
        followSliceSource.fetch = { _ in
            followSlicePage += 1
            return page(9_200 + followSlicePage, cursor: "following-slice:\(followSlicePage)")
        }
        let followSliceOwner = Task { await followSliceStore.activate(session: followSliceSource, filter: FeedFilter(kind: .video), source: .following) }
        await followSliceStarted.wait()
        followSliceStore.reconcileFollowing([], current: nil)
        releaseFollowSlice.open(); let followSliceResult = await followSliceOwner.value
        check(followSliceResult.status != .committed && followSlicePage == 4 && !followSliceStore.loading && followSliceStore.items.isEmpty,
              "Following membership changes invalidate a paused slice before stale requests or rows can resume")

        var stagedRetryClock = Date(timeIntervalSince1970: 3_000)
        let stagedErrorSource = FakeFeedSource(), stagedErrorStore = FeedStore(now: { stagedRetryClock }, slicePause: { _ in await Task.yield() })
        stagedErrorSource.fetch = { _ in page(9_300, video: true, cursor: "preserve-on-error") }
        _ = await stagedErrorStore.activate(session: stagedErrorSource, filter: FeedFilter(kind: .video), source: .discovery)
        var stagedErrorPage = 0
        stagedErrorSource.fetch = { _ in
            stagedErrorPage += 1
            if stagedErrorPage == 9 { throw ClientError.http(429) }
            if stagedErrorPage > 9 { return page(9_399, video: true) }
            return page(9_300 + stagedErrorPage, cursor: "staged-error:\(stagedErrorPage)")
        }
        let stagedErrorResult = await stagedErrorStore.restartFromStart(session: stagedErrorSource, filter: FeedFilter(kind: .video), source: .discovery)
        check(stagedErrorResult.status == .failedRetainingPrevious && stagedErrorResult.error != nil && stagedErrorPage == 9 &&
              stagedErrorStore.items.map(\.id) == [9_300] && !stagedErrorStore.reachedEnd &&
              stagedErrorStore.continuationSnapshot(windowIDs: [9_300])?.cursor == "preserve-on-error",
              "A ninth-batch staged rate-limit failure preserves the previous queue and cursor without claiming end")
        let stagedRequestsAtFailure = stagedErrorSource.requests.count
        _ = await stagedErrorStore.restartFromStart(session: stagedErrorSource, filter: FeedFilter(kind: .video), source: .discovery)
        check(stagedErrorSource.requests.count == stagedRequestsAtFailure,
              "A staged 429 cooldown suppresses an immediate explicit refresh without another RPC")
        check(stagedErrorStore.restartRetryAvailableAt.map { $0 > stagedRetryClock } == true && stagedErrorStore.continuationState == .ready,
              "Staged retry cooldown is separate from the retained queue's continuation state")
        stagedRetryClock = stagedRetryClock.addingTimeInterval(60)
        _ = await stagedErrorStore.restartFromStart(session: stagedErrorSource, filter: FeedFilter(kind: .video), source: .discovery)
        check(stagedErrorSource.requests.count == stagedRequestsAtFailure + 1 && stagedErrorStore.items.map(\.id) == [9_399] &&
              stagedErrorStore.restartRetryAvailableAt == nil,
              "Explicit staged retry after cooldown succeeds and clears its retry deadline")

        for contextChange in ["filter", "identity", "clear"] {
            let cooldownSource = FakeFeedSource(), cooldownStore = FeedStore(now: { stagedRetryClock })
            cooldownSource.fetch = { _ in throw URLError(.timedOut) }
            _ = await cooldownStore.restartFromStart(session: cooldownSource, filter: FeedFilter(kind: .video), source: .discovery)
            let requestsAtCooldown = cooldownSource.requests.count
            _ = await cooldownStore.restartFromStart(session: cooldownSource, filter: FeedFilter(kind: .video), source: .discovery)
            check(cooldownSource.requests.count == requestsAtCooldown && cooldownStore.restartRetryAvailableAt != nil,
                  "A network-failed staged restart has a cooldown too")
            if contextChange == "identity" { cooldownSource.feedIdentity = "new-cooldown-account" }
            if contextChange == "clear" { cooldownStore.clear(); check(cooldownStore.restartRetryAvailableAt == nil, "Clear removes the old account's staged cooldown") }
            cooldownSource.fetch = { _ in page(9_398, video: contextChange != "filter") }
            let targetFilter = FeedFilter(kind: contextChange == "filter" ? .image : .video)
            let freshContext = await cooldownStore.restartFromStart(session: cooldownSource, filter: targetFilter, source: .discovery)
            check(freshContext.status == .committed && cooldownSource.requests.count == requestsAtCooldown + 1 && cooldownStore.restartRetryAvailableAt == nil,
                  "A \(contextChange) change does not inherit an unrelated staged cooldown")
        }

        // The creating caller owns restart cancellation. Same-key joiners do
        // not acquire cancellation authority over that owner's work.
        let directCancelSource = FakeFeedSource(), directCancelStarted = Gate(), directCancelRelease = Gate()
        let directCancelStore = FeedStore()
        directCancelSource.fetch = { _ in page(9_400, video: true, cursor: "owner-preserved") }
        _ = await directCancelStore.activate(session: directCancelSource, filter: FeedFilter(kind: .video), source: .discovery)
        var cancelledPageObservedCancellation = false
        directCancelSource.requests = []
        directCancelSource.fetch = { _ in
            directCancelStarted.open(); await directCancelRelease.wait()
            cancelledPageObservedCancellation = Task.isCancelled
            return page(9_401, video: true, cursor: "must-not-install")
        }
        let directCancelOwner = Task { await directCancelStore.restartFromStart(session: directCancelSource, filter: FeedFilter(kind: .video), source: .discovery) }
        await directCancelStarted.wait(); directCancelOwner.cancel(); directCancelRelease.open()
        let directCancelResult = await directCancelOwner.value
        check(directCancelResult.status == .cancelled && cancelledPageObservedCancellation &&
              directCancelStore.items.map(\.id) == [9_400] && directCancelStore.continuationSnapshot(windowIDs: [9_400])?.cursor == "owner-preserved" &&
              directCancelSource.requests.count == 1 && !directCancelStore.continuationState.isLoading,
              "Cancelling the creating restart caller cancels its page and rejects a cancellation-ignoring late response")

        let directWaitSource = FakeFeedSource(), directWaitStarted = Gate()
        let directWaitStore = FeedStore(slicePause: { _ in directWaitStarted.open(); try await Task.sleep(for: .seconds(5)) })
        directWaitSource.fetch = { _ in page(9_500, video: true, cursor: "owner-wait-preserved") }
        _ = await directWaitStore.activate(session: directWaitSource, filter: FeedFilter(kind: .video), source: .discovery)
        var directWaitPage = 0
        directWaitSource.fetch = { _ in directWaitPage += 1; return page(9_500 + directWaitPage, cursor: "owner-wait:\(directWaitPage)") }
        let directWaitOwner = Task { await directWaitStore.restartFromStart(session: directWaitSource, filter: FeedFilter(kind: .video), source: .discovery) }
        await directWaitStarted.wait()
        let directWaitCancelledAt = Date()
        directWaitOwner.cancel(); let directWaitResult = await directWaitOwner.value
        check(directWaitResult.status == .cancelled && Date().timeIntervalSince(directWaitCancelledAt) < 1 && directWaitPage == 4 &&
              directWaitStore.items.map(\.id) == [9_500] && !directWaitStore.continuationState.isLoading,
              "Cancelling the creating restart caller interrupts its slice sleep promptly without a fifth request")

        print("FeedStoreChecks: \(checkCount) regression checks passed")
    }
}
