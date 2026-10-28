import Foundation

@MainActor private final class AvailabilityFake: TagCandidateSource {
    var feedIdentity = "acct-A"
    var calls: [(Int, String?, Int, FeedFilter, Bool)] = []
    var active = 0; var peak = 0
    var handler: (Int, String?, Int) async throws -> MediaPage = { _,_,_ in .init(items: [], metadata: .init(nextCursor: nil)) }
    func tagCandidates(tagID: Int, author: Creator?, filter: FeedFilter, cursor: String?, limit: Int) async throws -> MediaPage {
        calls.append((tagID,cursor,limit,filter,author == nil)); active += 1; peak = max(peak, active)
        defer { active -= 1 }
        return try await handler(tagID,cursor,limit)
    }
}

@MainActor private final class AvailabilityGate {
    var openGate = false
    var waiters: [CheckedContinuation<Void,Never>] = []
    func wait() async { if !openGate { await withCheckedContinuation { waiters.append($0) } } }
    func open() { openGate = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}

@main struct TagMediaAvailabilityChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ yes: @autoclosure () -> Bool, _ why: String) { checks += 1; precondition(yes(), why) }
        func page(_ tag: Int, _ ids: [Int], _ cursor: String? = nil, _ types: [String] = [], url: String? = nil,
                  tagName: String? = "fixture", creatorID: Int? = nil) -> MediaPage {
            let items = ids.enumerated().map { index, id in
                MediaItem(id: id, url: url ?? "https://image.civitai.com/x/\(id)", width: 1, height: 1,
                    type: types.indices.contains(index) ? types[index] : "image", username: "fixture", browsingLevel: 1,
                    thumbnail: nil, creatorID: creatorID, tags: [.init(id: tag, name: tagName)], postID: nil, metadata: nil)
            }
            return .init(items: items, metadata: .init(nextCursor: cursor))
        }
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let source = AvailabilityFake(), store = TagMediaAvailability(now: { clock })
        source.handler = { id,_,_ in id == 1 ? page(id,[1,2,3]) : page(id,[]) }
        await store.verify(tags: [.init(id: 1,name:"enough"),.init(id: 2,name:"zero")], source: source)
        check(store.result(tagID: 1,identity:"acct-A")?.state == .enough, "Three unique valid media establishes enough")
        check(store.isRecommended(tagID: 1, identity: "acct-A"), "Only enough results are recommended")
        check(store.result(tagID: 1,identity:"acct-A")?.countLowerBound == 3 && source.calls.allSatisfy{$0.2 == 20 && $0.3.kind == .all && $0.3.sort == "Newest" && $0.3.period == "AllTime" && !$0.3.onlyPG && $0.3.baseModel.isEmpty && $0.3.videoDurationRange == nil && $0.4}, "Probe uses the same page size and scope as normal single-tag search")
        let zero = store.result(tagID: 2,identity:"acct-A")
        check(zero?.state == .sparse && zero?.exhausted == true && zero?.countLowerBound == 0, "Empty exhausted feed is sparse")
        source.handler = { id,cursor,_ in
            if id == 3 { return page(id,[30,31]) }
            let next = cursor == nil ? "a" : cursor == "a" ? "b" : "c"
            return page(id,[],next)
        }
        await store.verify(tags: [.init(id:3,name:"two"),.init(id:4,name:"cursor-empty")],source:source)
        check(store.result(tagID:3,identity:"acct-A")?.state == .sparse && store.result(tagID:3,identity:"acct-A")?.countLowerBound == 2, "Two unique items at exhausted end is sparse")
        check(store.result(tagID:4,identity:"acct-A")?.state == .unknown && source.calls.filter{$0.0 == 4}.count == 3, "Empty pages with cursors continue but page cap stays unknown")

        let parityPage = page(5, [501, 502, 503])
        var realAccumulator = FeedAccumulator(blockedTags: [], deduplicateMediaAssets: true)
        realAccumulator.append(parityPage)
        source.handler = { _,_,_ in parityPage }
        await store.verify(tags: [.init(id: 5, name: "parity")], source: source)
        check(store.result(tagID: 5, identity: "acct-A")?.countLowerBound == realAccumulator.items.count,
              "Probe threshold count matches the real FeedAccumulator on the same page")
        check(store.result(tagID: 5, identity: "acct-A")?.reason == .thresholdReached, "Threshold result has an explicit reason")
        var partialItems = parityPage.items
        for index in partialItems.indices { partialItems[index].tags?.append(.init(id: nil, name: "unrelated")) }
        let partialPage = MediaPage(items: partialItems, metadata: .init(nextCursor: nil))
        let partialStore = TagMediaAvailability()
        source.handler = { _,_,_ in partialPage }
        await partialStore.verify(tags: [.init(id: 5, name: "parity")], source: source)
        check(partialStore.isRecommended(tagID: 5, identity: "acct-A") &&
              (try? partialPage.items.allSatisfy { try MediaSearchCriteria(tags:[.init(id:5,name:"parity")]).matches($0) }) == true,
              "Availability and normal criteria both accept witnessed IDs with unrelated incomplete labels")

        let validityStore = TagMediaAvailability()
        source.handler = { id,_,_ in page(id, [601,602,603], url: "") }
        await validityStore.verify(tags: [.init(id: 6, name: "empty url")], source: source)
        check(validityStore.result(tagID: 6, identity: "acct-A")?.state == .unknown &&
              validityStore.result(tagID: 6, identity: "acct-A")?.reason == .metadataMissing,
              "Empty media URLs remain UNKNOWN and cannot establish displayable availability")
        source.handler = { id,_,_ in page(id, [611,612,613]) }
        await validityStore.verify(tags: [.init(id: 7, name: "https")], source: source)
        check(validityStore.isRecommended(tagID: 7, identity: "acct-A"), "Valid HTTPS media URLs can establish availability")

        let policyStore = TagMediaAvailability()
        source.handler = { id,_,_ in page(id, [701,702,703], creatorID: 77) }
        let blockedAuthor = TagAvailabilityPolicy(blockedAuthorIDs: [77])
        await policyStore.verify(tags: [.init(id: 70, name: "author blocked")], source: source, policy: blockedAuthor)
        check(policyStore.result(tagID: 70, identity: "acct-A", policy: blockedAuthor)?.countLowerBound == 0,
              "Blocked authors are filtered by FeedAccumulator")
        let blockedTag = TagAvailabilityPolicy(blockedTags: ["fixture"])
        await policyStore.verify(tags: [.init(id: 70, name: "tag blocked")], source: source, policy: blockedTag)
        check(policyStore.result(tagID: 70, identity: "acct-A", policy: blockedTag)?.state == .sparse,
              "Blocked tags are filtered by FeedAccumulator")
        source.handler = { id,_,_ in page(id, [711,712,713], tagName: nil) }
        let missingNames = TagAvailabilityPolicy(blockedTags: ["blocked"])
        await policyStore.verify(tags: [.init(id: 71, name: "missing names")], source: source, policy: missingNames)
        check(policyStore.result(tagID: 71, identity: "acct-A", policy: missingNames)?.reason == .metadataMissing,
              "Missing tag names with a nonempty blocklist stay UNKNOWN")
        check(policyStore.result(tagID: 70, identity: "acct-A", policy: .init()) == nil &&
              policyStore.result(tagID: 70, identity: "acct-A", policy: blockedTag) != nil,
              "Policy changes use a distinct cache key")

        let duplicateAssetStore = TagMediaAvailability()
        source.handler = { id,_,_ in page(id, [801,802,803], url: "https://image.civitai.com/x/shared") }
        await duplicateAssetStore.verify(tags: [.init(id: 80, name: "dedup")], source: source)
        let dedupResult = duplicateAssetStore.result(tagID: 80, identity: "acct-A")
        check(dedupResult?.state == .sparse && dedupResult?.countLowerBound == 1,
              "Three IDs sharing one media asset deduplicate to one visible item")
        let noDedup = TagAvailabilityPolicy(deduplicateMediaAssets: false)
        await duplicateAssetStore.verify(tags: [.init(id: 80, name: "dedup off")], source: source, policy: noDedup)
        check(duplicateAssetStore.isRecommended(tagID: 80, identity: "acct-A", policy: noDedup),
              "Disabling media asset deduplication admits three unique IDs")

        let nilTypeStore = TagMediaAvailability()
        source.handler = { id,_,_ in
            let first = MediaItem(id: 901, url: "https://image.civitai.com/x/901", width: 1, height: 1, type: nil,
                username: "fixture", browsingLevel: 1, thumbnail: nil, creatorID: nil, tags: [.init(id: id, name: "fixture")], postID: nil, metadata: nil)
            let rest = page(id, [902,903]).items
            return .init(items: [first] + rest, metadata: .init(nextCursor: nil))
        }
        await nilTypeStore.verify(tags: [.init(id: 90, name: "nil type")], source: source)
        check(nilTypeStore.isRecommended(tagID: 90, identity: "acct-A"), "Nil media type follows real isSupported behavior")

        let cases: [(String,(Int,String?,Int) async throws -> MediaPage)] = [
            ("network", {_,_,_ in throw URLError(.timedOut)}),
            ("wrong-tag", {_,_,_ in page(999,[51])}),
            ("duplicate-page", {id,cursor,_ in cursor == nil ? page(id,[60],"c") : page(id,[60])}),
            ("cursor-loop", {_,cursor,_ in page(7,[],cursor == nil ? "loop" : "loop")}),
            ("unsupported-type", {id,_,_ in page(id,[80],[].first, ["model"])}),
            ("truncated", {id,_,_ in page(id,[90],"more")})
        ]
        for (offset, item) in cases.enumerated() {
            source.handler = item.1
            let id = 10 + offset
            await store.verify(tags:[.init(id:id,name:item.0)],source:source)
            check(store.result(tagID:id,identity:"acct-A")?.state == .unknown, "\(item.0) stays UNKNOWN")
            if item.0 == "duplicate-page" { check(source.calls.filter { $0.0 == id }.count == 2, "Repeated-page case actually reads both correctly scoped pages") }
        }
        source.handler = { _,_,_ in throw ClientError.http(503) }
        await store.verify(tags: [.init(id: 20, name: "http")], source: source)
        check(store.result(tagID: 20, identity: "acct-A")?.reason == .http &&
              store.result(tagID: 20, identity: "acct-A")?.httpStatus == 503,
              "HTTP failures preserve the status and remain UNKNOWN")
        let pageLimitResult = store.result(tagID: 4, identity: "acct-A")
        check(pageLimitResult?.reason == .pageLimit && pageLimitResult?.pages == 3 && pageLimitResult?.hasMore == true,
              "Page budget exhaustion reports page count and remaining cursor")
        source.feedIdentity = "acct-B"
        check(store.result(tagID:1,identity:"acct-B") == nil && store.result(tagID:1,identity:"acct-A")?.state == .enough, "Cache is isolated by feed identity")
        source.handler = { id,_,_ in page(id,[]) }
        await store.verify(tags:[.init(id:1,name:"same")],source:source)
        check(store.result(tagID:1,identity:"acct-B")?.state == .sparse, "Identity-specific probe writes a separate entry")
        clock.addTimeInterval(31)
        check(store.result(tagID:10,identity:"acct-A") == nil && store.result(tagID:1,identity:"acct-B") != nil, "UNKNOWN TTL is 30 seconds while sparse TTL remains longer")
        clock.addTimeInterval(570)
        check(store.result(tagID:1,identity:"acct-B") == nil, "Sparse TTL is 10 minutes")

        clock = Date(timeIntervalSince1970: 1_800_000_000)
        let ttl = TagMediaAvailability(now:{clock})
        source.handler = { id,_,_ in page(id,[1,2,3]) }
        await ttl.verify(tags:[.init(id:201,name:"enough ttl")],source:source)
        clock.addTimeInterval(3599)
        check(ttl.result(tagID:201,identity:"acct-B") != nil, "Enough result remains cached for one hour")
        clock.addTimeInterval(2)
        check(ttl.result(tagID:201,identity:"acct-B") == nil, "Enough result expires after one hour")

        let switchingSource = AvailabilityFake(), switchingStore = TagMediaAvailability()
        switchingSource.handler = { id,_,_ in
            let response = page(id,[]); switchingSource.feedIdentity = "acct-C"; return response
        }
        await switchingStore.verify(tags:[.init(id:301,name:"switch")],source:switchingSource)
        check(switchingStore.result(tagID:301,identity:"acct-A") == nil && switchingStore.result(tagID:301,identity:"acct-C") == nil, "Identity change during await commits no stale entry")

        let gatedSource = AvailabilityFake(), gatedStore = TagMediaAvailability(), gate = AvailabilityGate()
        gatedSource.handler = { id,_,_ in await gate.wait(); return page(id,[]) }
        let firstBatch = Task { await gatedStore.verify(tags:[.init(id:401,name:"flight")],source:gatedSource) }
        while gatedSource.calls.isEmpty { await Task.yield() }
        let duplicateBatch = Task { await gatedStore.verify(tags:[.init(id:401,name:"duplicate caller")],source:gatedSource) }
        for _ in 0..<5 { await Task.yield() }
        check(gatedSource.calls.count == 1, "Concurrent caller does not duplicate active probe")
        gate.open(); await firstBatch.value; await duplicateBatch.value
        check(gatedSource.calls.count == 1 && gatedStore.isSparse(tagID:401,identity:"acct-A"), "Successful admitted batch supplies the waiting duplicate caller without another request")
        let cancelSource = AvailabilityFake(), cancelStore = TagMediaAvailability()
        cancelSource.handler = { id,_,_ in try await Task.sleep(nanoseconds: 5_000_000_000); return page(id,[]) }
        let cancelled = Task { await cancelStore.verify(tags:[.init(id:402,name:"cancel")],source:cancelSource) }
        while cancelSource.calls.isEmpty { await Task.yield() }
        cancelled.cancel(); await cancelled.value
        check(cancelStore.result(tagID:402,identity:"acct-A") == nil, "Cancellation does not cache UNKNOWN from an abandoned batch")

        let replacingSource = AvailabilityFake(), replacingStore = TagMediaAvailability(), replaceGate = AvailabilityGate()
        replacingSource.handler = { id,_,_ in
            if id == 410 { await replaceGate.wait() }
            return page(id,[])
        }
        let abandoned = Task { await replacingStore.verify(tags:[.init(id:410,name:"previous query")],source:replacingSource) }
        while replacingSource.calls.isEmpty { await Task.yield() }
        let replacement = Task { await replacingStore.verify(tags:[.init(id:411,name:"new query")],source:replacingSource) }
        for _ in 0..<5 { await Task.yield() }
        check(replacingSource.calls.count == 1, "A different query waits for the old batch without extra concurrent requests")
        abandoned.cancel(); replaceGate.open()
        await abandoned.value; await replacement.value
        check(replacingStore.result(tagID:410,identity:"acct-A") == nil && replacingStore.isSparse(tagID:411,identity:"acct-A"), "Replacement query still runs after cancelled batch releases admission")

        for switchesAccount in [false, true] {
            let identicalSource = AvailabilityFake(), identicalStore = TagMediaAvailability(), sameGate = AvailabilityGate()
            identicalSource.handler = { id,_,_ in await sameGate.wait(); return page(id,[]) }
            let owner = Task { await identicalStore.verify(tags:[.init(id:420,name:"identical")],source:identicalSource) }
            while identicalSource.calls.isEmpty { await Task.yield() }
            if switchesAccount { identicalSource.feedIdentity = "acct-B" }
            let nextOwner = Task { await identicalStore.verify(tags:[.init(id:420,name:"identical")],source:identicalSource) }
            for _ in 0..<5 { await Task.yield() }
            owner.cancel(); sameGate.open()
            await owner.value; await nextOwner.value
            let identity = switchesAccount ? "acct-B" : "acct-A"
            check(identicalSource.calls.count == 2 && identicalStore.isSparse(tagID:420,identity:identity) && identicalSource.peak <= 2,
                  "Cancelled identical owner releases admission for the waiting caller, including account replacement")
            if switchesAccount { check(identicalStore.result(tagID:420,identity:"acct-A") == nil, "No cancelled old-account result leaks across replacement") }
        }

        let capped = TagMediaAvailability(maxEntries: 2, maxTagsPerBatch: 12, now:{clock})
        let laterValid = AvailabilityFake(), laterStore = TagMediaAvailability()
        laterValid.handler = { id,cursor,_ in cursor == nil ? page(id,[501],"valid-next",url: "") : page(id,[502,503,504]) }
        await laterStore.verify(tags:[.init(id:501,name:"bad first row then valid witnesses")],source:laterValid)
        check(laterStore.isRecommended(tagID:501,identity:"acct-A") && laterValid.calls.count == 2,
              "An unusable early row cannot suppress three valid later witnesses within the scan budget")
        laterStore.recordEmptySearch(tagID:501,identity:"acct-A",policy:.init())
        check(!laterStore.isRecommended(tagID:501,identity:"acct-A") && laterStore.result(tagID:501,identity:"acct-A")?.reason == .searchEmpty,
              "A confirmed empty same-scope search immediately withdraws a cached recommendation without claiming global zero")
        await capped.verify(tags:(101...103).map{.init(id:$0,name:"\($0)")},source:source)
        check(capped.checkedCount(identity:"acct-B") == 2, "Cache evicts to configured cap")
        let limitedSource = AvailabilityFake(), limited = TagMediaAvailability()
        limitedSource.handler = { id,_,_ in try await Task.sleep(for: .milliseconds(20)); return page(id,[]) }
        let twenty = (1...20).map{SearchTag(id:$0,name:"\($0)")}
        await limited.verify(tags:twenty + twenty, source:limitedSource)
        check(limitedSource.calls.count == 12 && Set(limitedSource.calls.map{$0.0}).count == 12, "One batch probes at most 12 distinct tags")
        check(limitedSource.peak == 2, "Suspending source exercises exactly two probes without exceeding the bound")
        print("TagMediaAvailabilityChecks: \(checks) assertions passed")
    }
}
