import Foundation

@MainActor private final class DurationSource: FeedPageReading {
    var feedIdentity = "fixture:1"
    var pageCalls = 0
    var metadataCalls = 0
    var lastIDs: [Int] = []
    var lastPosts: [Int] = []
    var requestedCursors: [String?] = []
    var fetch: (String?) async throws -> MediaPage = { _ in .init(items: [], metadata: .init(nextCursor: nil)) }
    var durationFetch: () async throws -> [VideoDurationRecord] = { [] }
    func mediaPage(filter: FeedFilter, cursor: String?, creator: Creator?, followed: Bool, includeTags: Bool) async throws -> MediaPage {
        pageCalls += 1; requestedCursors.append(cursor); return try await fetch(cursor)
    }
    func searchMediaPage(target: MediaSearchTarget, filter: FeedFilter, cursor: String?, includeTags: Bool) async throws -> MediaPage { try await mediaPage(filter: filter, cursor: cursor, creator: nil, followed: false, includeTags: includeTags) }
    func collectionPage(id: Int, filter: FeedFilter, cursor: String?, allAccessibleLevels: Bool, includeTags: Bool) async throws -> MediaPage { try await mediaPage(filter: filter, cursor: cursor, creator: nil, followed: false, includeTags: includeTags) }
    func videoDurationMetadata(ids: [Int], postIDs: [Int], onlyPG: Bool) async throws -> [VideoDurationRecord] {
        metadataCalls += 1; lastIDs = ids; lastPosts = postIDs; return try await durationFetch()
    }
}
@MainActor private final class DurationGate {
    var continuation: CheckedContinuation<Void, Never>?
    var opened = false
    func wait() async { if !opened { await withCheckedContinuation { continuation = $0 } } }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}
@main struct VideoDurationChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func item(_ id: Int, _ duration: Double? = nil, post: Int? = 10, video: Bool = true) -> MediaItem {
            var value = MediaItem(id: id, url: "https://example.com/\(id)", width: nil, height: nil, type: video ? "video" : "image", username: nil, browsingLevel: 1, thumbnail: nil)
            value.postID = post; value.metadata = VideoTechnicalMetadata(duration: duration); return value
        }
        func page(_ items: [MediaItem], _ cursor: String? = nil) -> MediaPage { .init(items: items, metadata: .init(nextCursor: cursor)) }
        let finite = VideoDurationRange(minimumSeconds: 2, maximumSeconds: 120)
        check(finite.contains(119.9) && finite.contains(120) && !finite.contains(120.1), "finite maximum is inclusive without rounding")
        let long = VideoDurationRange(minimumSeconds: 120)
        check(!long.contains(119.9) && long.contains(120) && long.contains(120.1) && long.contains(900), "120 lower means all >= 120")
        check(!finite.contains(nil) && !finite.contains(0) && !finite.contains(-1) && !finite.contains(.infinity) && !finite.contains(.nan), "unknown and invalid never match active")
        check(VideoDurationRange(minimumSeconds: 30, maximumSeconds: 30).contains(30), "equal finite endpoints valid")
        check(VideoDurationRange(minimumSeconds: 90, maximumSeconds: 5).maximumSeconds == 90, "crossed initialization clamps upper")
        check(VideoDurationRange(minimumSeconds: -1, maximumSeconds: 900) == .init(minimumSeconds: 2, maximumSeconds: 120), "outer bounds clamp")
        for index in VideoDurationScale.seconds.indices {
            let value = VideoDurationScale.seconds[index]
            check(VideoDurationScale.index(for: value) == index, "exact ladder index")
            check(VideoDurationScale.movingLower(index, in: .init()).minimumSeconds == value, "lower ladder")
            check(VideoDurationScale.movingUpper(index, in: .init()).maximumSeconds == value, "upper ladder")
        }
        check(VideoDurationScale.movingUpper(VideoDurationScale.terminalIndex, in: finite).maximumSeconds == nil, "far right removes maximum")
        check(VideoDurationScale.movingLower(99, in: .init(minimumSeconds: 2, maximumSeconds: 15)).minimumSeconds == 15, "lower does not cross upper")
        check(VideoDurationScale.movingUpper(-10, in: .init(minimumSeconds: 90)).maximumSeconds == 90, "upper does not cross lower")
        let beyondTwo = VideoDurationRange(minimumSeconds: 120, minimumIsExclusive: true)
        check(!beyondTwo.contains(119.9) && !beyondTwo.contains(120) && beyondTwo.contains(120.0001) && beyondTwo.contains(120.1), "exclusive terminal is strictly >120 without rounding up to 121")
        check(!beyondTwo.contains(nil) && !beyondTwo.contains(.infinity) && !beyondTwo.contains(.nan), "exclusive terminal still rejects unknown and non-finite metadata")
        check(long.minimumTitle == "02:00" && beyondTwo.minimumTitle == "超过02:00" && beyondTwo.maximumTitle == "不限", "inclusive finite 120 and exclusive terminal have distinct exact labels")
        check(VideoDurationRange(minimumSeconds: 120, maximumSeconds: 120).contains(120), "finite equal 120 endpoints retain the exact value")
        check(VideoDurationRange(minimumSeconds: 120, maximumSeconds: 30, minimumIsExclusive: true) == beyondTwo, "invalid exclusive plus finite upper normalizes to a nonempty unbounded range")
        check(!VideoDurationRange(minimumSeconds: 119, minimumIsExclusive: true).minimumIsExclusive, "only the special 120 lower terminal may be exclusive")
        check(Set([long, beyondTwo]).count == 2, "inclusive and exclusive ranges differ in equality and hashing")
        check(VideoDurationScale.seconds == Array(2...120) && VideoDurationScale.terminalIndex == 119, "119 finite one-second positions precede a separate state index")
        check(VideoDurationScale.lowerIndex(long) == VideoDurationScale.finiteLastIndex && VideoDurationScale.lowerIndex(beyondTwo) == VideoDurationScale.terminalIndex, "legacy 120 and new terminal have distinct handle positions")
        check(VideoDurationScale.movingLower(VideoDurationScale.terminalIndex, in: .init()) == beyondTwo, "new lower terminal sets min120 plus explicit exclusivity")
        check(VideoDurationScale.movingLower(VideoDurationScale.finiteLastIndex, in: beyondTwo) == long, "one backward step from special terminal returns inclusive 120")
        check(VideoDurationScale.movingUpper(VideoDurationScale.finiteLastIndex, in: beyondTwo) == beyondTwo, "exclusive lower prevents a finite empty upper interval")
        check(VideoDurationScale.movingLower(VideoDurationScale.terminalIndex, in: finite) == .init(minimumSeconds: 120, maximumSeconds: 120), "finite upper clamps lower before the exclusive terminal")
        let displayExamples = [(2,"00:02"), (30,"00:30"), (59,"00:59"), (60,"01:00"), (90,"01:30"), (119,"01:59"), (120,"02:00")]
        for (seconds, expected) in displayExamples {
            check(VideoDurationScale.title(seconds) == expected, "explicit finite labels use mm:ss including minute boundaries")
        }
        for seconds in 2...120 {
            let index = VideoDurationScale.index(for: seconds)
            let title = VideoDurationScale.title(seconds)
            let parts = title.split(separator: ":")
            check(title.count == 5 && parts.count == 2 && parts.allSatisfy { $0.count == 2 } && (Int(parts[0]) ?? -1) * 60 + (Int(parts[1]) ?? -1) == seconds, "every fixed-width finite label reads back to its exact seconds")
            if seconds < 120 {
                check(VideoDurationScale.movingLower(index + 1, in: .init(minimumSeconds: seconds)).minimumSeconds == seconds + 1, "lower advances precisely one second")
                check(VideoDurationScale.movingUpper(index + 1, in: .init(maximumSeconds: seconds)).maximumSeconds == seconds + 1, "upper advances precisely one second")
            }
            for finiteFraction in [0.75, 0.8, 0.9] {
                let fraction = VideoDurationScale.fraction(for: index, finiteFraction: finiteFraction)
                check(VideoDurationScale.index(atFraction: fraction, finiteFraction: finiteFraction) == index, "every finite drag position roundtrips across track widths")
            }
        }
        check(VideoDurationScale.tickSeconds == [30,60,90,120], "only meaningful finite tick labels are present")
        let finiteSpan = 0.8
        for seconds in VideoDurationScale.tickSeconds {
            let fraction = VideoDurationScale.fraction(for: VideoDurationScale.index(for: seconds), finiteFraction: finiteSpan)
            check(abs(fraction - Double(seconds - 2) / 118 * finiteSpan) < 0.000001, "tick geometry follows the finite seconds scale")
        }
        check(VideoDurationScale.fraction(for: VideoDurationScale.terminalIndex, finiteFraction: finiteSpan) == 1 && VideoDurationScale.fraction(for: VideoDurationScale.finiteLastIndex, finiteFraction: finiteSpan) == finiteSpan, "special terminal has separate physical space from finite 120")
        check(VideoDurationScale.index(atFraction: -1, finiteFraction: finiteSpan) == 0 && VideoDurationScale.index(atFraction: 2, finiteFraction: finiteSpan) == VideoDurationScale.terminalIndex, "drag outside track clamps to real endpoints")
        check(VideoDurationScale.index(atFraction: finiteSpan + 0.02, finiteFraction: finiteSpan) == VideoDurationScale.finiteLastIndex && VideoDurationScale.index(atFraction: 0.99, finiteFraction: finiteSpan) == VideoDurationScale.terminalIndex, "terminal space does not introduce fabricated finite seconds")
        let decoder = JSONDecoder()
        for extra in ["", ",\"minimumIsExclusive\":false", ",\"minimumIsExclusive\":null"] {
            let legacy = try decoder.decode(VideoDurationRange.self, from: Data("{\"minimumSeconds\":120\(extra)}".utf8))
            check(legacy == long && legacy.contains(120) && legacy.minimumTitle == "02:00", "legacy min120 remains inclusive without an explicit true discriminator")
        }
        let beyondEncoded = try JSONEncoder().encode(beyondTwo)
        let beyondJSON = try JSONSerialization.jsonObject(with: beyondEncoded) as! [String: Any]
        check(beyondJSON["minimumSeconds"] as? Int == 120 && beyondJSON["minimumIsExclusive"] as? Bool == true && beyondJSON["maximumSeconds"] == nil, "exclusive persistence stores seconds120 plus boolean and absent upper, never 121 or Infinity")
        check(try decoder.decode(VideoDurationRange.self, from: beyondEncoded) == beyondTwo, "exclusive terminal roundtrips through persistence")
        let inclusiveJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(long)) as! [String: Any]
        check(inclusiveJSON["minimumIsExclusive"] == nil, "inclusive persistence preserves the legacy optional-field shape")
        let invalidExclusive = try decoder.decode(VideoDurationRange.self, from: Data("{\"minimumSeconds\":120,\"maximumSeconds\":120,\"minimumIsExclusive\":true}".utf8))
        check(invalidExclusive == beyondTwo && invalidExclusive.contains(120.1), "decoded empty exclusive interval is normalized consistently")
        for raw in ["null", "0", "-5", "\"30\"", "true", "{}", "[]"] {
            let data = Data("{\"id\":1,\"url\":\"https://example.com/1\",\"type\":\"video\",\"metadata\":{\"duration\":\(raw)},\"meta\":{\"duration\":99}}".utf8)
            let decoded = try decoder.decode(MediaItem.self, from: data)
            check(decoded.durationSeconds == nil, "invalid duration stays unknown: \(raw)")
        }
        for extra in ["", ",\"metadata\":null", ",\"metadata\":{}", ",\"metadata\":5", ",\"meta\":{\"duration\":30}"] {
            check(try decoder.decode(MediaItem.self, from: Data("{\"id\":1,\"url\":\"https://example.com/1\"\(extra)}".utf8)).durationSeconds == nil, "missing technical metadata cannot use generation meta")
        }
        let numeric = try decoder.decode(MediaItem.self, from: Data("{\"id\":1,\"url\":\"https://example.com/1\",\"metadata\":{\"duration\":120.1}}".utf8))
        check(numeric.durationSeconds == 120.1, "numeric technical seconds preserved")
        let oldFilter = try decoder.decode(FeedFilter.self, from: Data("{\"kind\":\"all\",\"sort\":\"Newest\",\"period\":\"Week\",\"baseModel\":\"\",\"onlyPG\":false}".utf8))
        check(oldFilter.videoDurationRange == nil, "old persisted filter remains disabled")
        var active = oldFilter; active.videoDurationRange = long
        check(active.effectiveKind == .video && active.kind == .all, "active range presents videos while preserving the prior disabled selection")
        check(active.selecting(kind: .image).videoDurationRange == nil && active.selecting(kind: .image).effectiveKind == .image, "explicit image selection clears the incompatible video range")
        check(active.selecting(kind: .all).videoDurationRange == nil && active.selecting(kind: .video).videoDurationRange == long, "all clears range while video selection preserves it")
        let encoded = try JSONEncoder().encode(active)
        check(try decoder.decode(FeedFilter.self, from: encoded) == active && active != oldFilter, "range persists and participates in equality")
        var exclusiveFilter = active; exclusiveFilter.videoDurationRange = beyondTwo
        check(try decoder.decode(FeedFilter.self, from: JSONEncoder().encode(exclusiveFilter)) == exclusiveFilter && exclusiveFilter != active, "FeedFilter persists and distinguishes the new boundary without changing its outer shape")
        var legacyFilterJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldFilter)) as! [String: Any]
        legacyFilterJSON["videoDurationRange"] = ["minimumSeconds": 120]
        let recoveredFilter = try decoder.decode(FeedFilter.self, from: JSONSerialization.data(withJSONObject: legacyFilterJSON))
        check(recoveredFilter.videoDurationRange == long && recoveredFilter.videoDurationRange!.contains(120), "legacy saved FeedFilter with min120 restores >=120 instead of becoming strict")
        check(active.resetting(in: .discovery).videoDurationRange == nil, "reset disables range")
        check(active.query().first { $0.name == "type" }?.value == "video" && active.kind == .all, "range requests video without changing selected kind")
        check(!active.query().contains { $0.name.lowercased().contains("duration") }, "no invented server duration parameters")
        _ = try decoder.decode(MediaPage.self, from: Data("{\"items\":[],\"metadata\":{}}".utf8))
        var unfiltered = FeedAccumulator()
        unfiltered.append(page([item(1, 1), item(2), item(3, video: false)]))
        check(unfiltered.items.count == 3, "disabled preserves short unknown and images")
        var filtered = FeedAccumulator(videoDurationRange: finite)
        filtered.append(page([item(1, 1), item(2), item(3, 120), item(4, 120.1), item(5, video: false)], "next"))
        check(filtered.items.map(\.id) == [3] && filtered.unverifiedDuration == 1 && filtered.hiddenByDuration == 3, "range counters separate unknown from mismatch")
        check(!filtered.reachedEnd && filtered.cursor == "next", "filtered page retains cursor")
        var exclusiveFiltered = FeedAccumulator(videoDurationRange: beyondTwo)
        exclusiveFiltered.append(page([item(30, 119.9), item(31, 120), item(32, 120.0001), item(33, 120.1), item(34)]))
        check(exclusiveFiltered.items.map(\.id) == [32,33] && exclusiveFiltered.unverifiedDuration == 1, "production accumulator enforces strict terminal while keeping missing metadata unknown")
        let candidates = [item(3, post: 30), item(1, post: 10), item(2, post: 30), item(4, post: nil), item(5, 30), item(6, video: false), item(3, post: 30)]
        let batch = VideoDurationBatch(items: candidates)
        check(batch.ids == [3,1,2] && batch.postIDs == [30,10], "only unknown video original posts deduplicated preserving order")
        let merged = batch.merging([.init(id: 1, metadata: .init(duration: 11)), .init(id: 999, metadata: .init(duration: 99)), .init(id: 3, metadata: .init(duration: 33))], into: candidates)
        check(merged.map(\.id) == candidates.map(\.id) && merged[0].durationSeconds == 33 && merged[1].durationSeconds == 11 && merged[2].durationSeconds == nil && merged[3].durationSeconds == nil, "rekey by ID ignores unexpected and missing rows")
        check(VideoDurationBatch(items: (1...30).map { item($0, post: $0) }).ids.count == 20, "one enrichment batch caps at 20")
        let following = try decoder.decode(FollowingIndexPage.self, from: Data("{\"items\":[{\"id\":2,\"user\":{\"id\":5},\"metadata\":{\"duration\":8.5}}],\"nextCursor\":null}".utf8))
        check(following.items.first?.metadata?.duration == 8.5, "following technical metadata retained")
        var retryClock = Date(timeIntervalSince1970: 4_000)
        let site = DurationSource(), store = FeedStore(now: { retryClock })
        site.fetch = { _ in page([item(1)]) }; site.durationFetch = { [.init(id: 1, metadata: .init(duration: 121))] }
        _ = await store.activate(session: site, filter: oldFilter, source: .discovery)
        check(site.metadataCalls == 0 && store.items.count == 1, "disabled performs zero enrichment calls")
        _ = await store.activate(session: site, filter: active, source: .discovery)
        check(site.metadataCalls == 1 && store.items.first?.durationSeconds == 121, "enabled enriches once before filtering")
        site.durationFetch = { throw ClientError.http(403) }
        site.fetch = { _ in page([item(1)], "cursor-\(site.pageCalls)") }
        site.pageCalls = 0; site.metadataCalls = 0
        _ = await store.activate(session: site, filter: active, source: .discovery, force: true)
        check(site.pageCalls == 1 && site.metadataCalls == 1 && store.items.isEmpty && !store.reachedEnd &&
              store.unverifiedDuration == 0 && store.durationMetadataFailedPages == 1 && store.continuationState.failure != nil,
              "failed enrichment stops before appending unknown media or advancing its source cursor")
        _ = await store.next(session: site)
        check(site.pageCalls == 1 && site.metadataCalls == 1 && !store.reachedEnd, "failed enrichment cooldown prevents repeated source and metadata calls")
        retryClock = retryClock.addingTimeInterval(60)
        site.fetch = { cursor in check(cursor == nil, "enrichment retry reuses the failed nil cursor"); return page([item(1)]) }
        site.durationFetch = { [.init(id: 1, metadata: .init(duration: 130))] }
        _ = await store.next(session: site)
        check(site.pageCalls == 2 && site.metadataCalls == 2 && store.items.map(\.id) == [1] && store.reachedEnd,
              "explicit retry after metadata recovery admits only a known matching duration")

        for status in [403, 429] {
            var failureClock = Date(timeIntervalSince1970: 5_000)
            let failureSource = DurationSource(), failureStore = FeedStore(now: { failureClock })
            failureSource.fetch = { _ in page([item(301, 130)], "retained-duration-tail") }
            _ = await failureStore.activate(session: failureSource, filter: active, source: .discovery)
            failureSource.fetch = { cursor in
                check(cursor == "retained-duration-tail", "metadata failure does not consume its source page")
                return page([item(302)], "must-not-advance")
            }
            failureSource.durationFetch = { throw ClientError.http(status) }
            _ = await failureStore.next(session: failureSource)
            check(failureSource.pageCalls == 2 && failureSource.metadataCalls == 1 && failureStore.items.map(\.id) == [301] &&
                  failureStore.continuationSnapshot(windowIDs: [301])?.cursor == "retained-duration-tail" && !failureStore.reachedEnd,
                  "persistent HTTP \(status) enrichment failure returns after one page and preserves the old media/cursor")
            check(failureStore.retryAvailableAt?.timeIntervalSince(failureClock) == (status == 429 ? 3 : 0.5),
                  "known metadata HTTP status controls retry cooldown without inventing status")
            _ = await failureStore.nextAutomatically(session: failureSource); _ = await failureStore.next(session: failureSource)
            check(failureSource.pageCalls == 2 && failureSource.metadataCalls == 1, "persistent enrichment failure cannot automatically scan or retry")
            failureClock = failureClock.addingTimeInterval(60)
            failureSource.fetch = { cursor in check(cursor == "retained-duration-tail", "recovered metadata re-fetches the original pending cursor"); return page([item(302)]) }
            failureSource.durationFetch = { [.init(id: 302, metadata: .init(duration: 130))] }
            _ = await failureStore.next(session: failureSource)
            check(failureStore.items.map(\.id) == [301,302] && failureStore.reachedEnd && failureSource.metadataCalls == 2,
                  "recovered metadata appends the pending matching work exactly once")
        }

        let unknownFailureSource = DurationSource()
        unknownFailureSource.durationFetch = { throw URLError(.timedOut) }
        let unknownFailurePage = try await unknownFailureSource.enrichVideoDurations(in: page([item(401)]), filter: active)
        check(unknownFailurePage.durationEnrichmentFailed && unknownFailurePage.durationEnrichmentHTTPStatus == nil,
              "a non-HTTP metadata error retains unknown HTTP evidence")

        var restartClock = Date(timeIntervalSince1970: 6_000)
        let enrichmentRestartSource = DurationSource(), enrichmentRestartStore = FeedStore(now: { restartClock })
        enrichmentRestartSource.fetch = { _ in page([item(501, 130)], "old-enriched-tail") }
        _ = await enrichmentRestartStore.activate(session: enrichmentRestartSource, filter: active, source: .discovery)
        enrichmentRestartSource.fetch = { _ in page([item(502)], "must-not-commit") }
        enrichmentRestartSource.durationFetch = { throw ClientError.http(429) }
        let enrichmentRestart = await enrichmentRestartStore.restartFromStart(session: enrichmentRestartSource, filter: active, source: .discovery)
        check(enrichmentRestart.status == .failedRetainingPrevious && enrichmentRestartSource.pageCalls == 2 && enrichmentRestartSource.metadataCalls == 1 &&
              enrichmentRestartStore.items.map(\.id) == [501] && enrichmentRestartStore.continuationSnapshot(windowIDs: [501])?.cursor == "old-enriched-tail" &&
              enrichmentRestartStore.continuationState == .ready && enrichmentRestartStore.restartRetryAvailableAt?.timeIntervalSince(restartClock) == 3,
              "staged enrichment failure preserves the committed queue and has an independent 429 cooldown")
        _ = await enrichmentRestartStore.restartFromStart(session: enrichmentRestartSource, filter: active, source: .discovery)
        check(enrichmentRestartSource.pageCalls == 2 && enrichmentRestartSource.metadataCalls == 1, "staged enrichment cooldown suppresses all repeated RPCs")
        restartClock = restartClock.addingTimeInterval(60)
        enrichmentRestartSource.fetch = { cursor in check(cursor == nil, "staged enrichment recovery retries from the original nil cursor"); return page([item(502)]) }
        enrichmentRestartSource.durationFetch = { [.init(id: 502, metadata: .init(duration: 130))] }
        _ = await enrichmentRestartStore.restartFromStart(session: enrichmentRestartSource, filter: active, source: .discovery)
        check(enrichmentRestartStore.items.map(\.id) == [502] && enrichmentRestartStore.reachedEnd && enrichmentRestartStore.restartRetryAvailableAt == nil,
              "successful staged metadata recovery atomically installs only matching results and clears cooldown")
        let started = DurationGate(), release = DurationGate()
        site.fetch = { _ in page([item(1)]) }
        site.durationFetch = { started.open(); await release.wait(); return [.init(id: 1, metadata: .init(duration: 130))] }
        let stale = Task { await store.activate(session: site, filter: active, source: .discovery, force: true) }
        await started.wait()
        site.fetch = { _ in page([item(2, 3)]) }
        let current = await store.activate(session: site, filter: oldFilter, source: .discovery)
        release.open(); _ = await stale.value
        check(store.items.map(\.id) == [2] && store.accepts(current, identity: site.feedIdentity), "old enriched response after range change cannot commit")
        let accountStarted = DurationGate(), accountRelease = DurationGate()
        site.fetch = { _ in page([item(1)]) }
        site.durationFetch = { accountStarted.open(); await accountRelease.wait(); return [] }
        let accountTask = Task { await store.activate(session: site, filter: active, source: .discovery, force: true) }
        await accountStarted.wait(); site.feedIdentity = "fixture:2"; accountRelease.open()
        let accountResult = await accountTask.value
        check(!accountResult.didCommit && store.items.isEmpty, "account change cannot turn old metadata into empty new-account commit")
        // A saved reading window can exceed a normal 20-item metadata batch.
        let restoreSource = DurationSource()
        let savedItems = (101...130).map { item($0, post: $0 + 1_000) }
        let savedIDs = savedItems.map(\.id)
        let savedContinuation = TimelineContinuation(cursor: "saved-window-tail-130", reachedEnd: false)!
        var restoreBatches: [[Int]] = []
        var restorePostBatches: [[Int]] = []
        restoreSource.durationFetch = {
            let ids = restoreSource.lastIDs
            restoreBatches.append(ids); restorePostBatches.append(restoreSource.lastPosts)
            return ids.reversed().map { .init(id: $0, metadata: .init(duration: 120 + Double($0 - 100))) }
        }
        let restored = try await restoreSource.enrichRestoredVideoDurations(savedItems, filter: active, isCurrent: { true })
        check(restoreSource.metadataCalls == 2 && restoreBatches.map(\.count) == [20,10] && restoreBatches.allSatisfy { $0.count <= 20 }, "30-item restore uses exactly two bounded metadata calls")
        check(restoreBatches.flatMap { $0 } == savedIDs && restorePostBatches.flatMap { $0 } == savedItems.compactMap(\.postID), "restore covers all original IDs and posts in order")
        check(restored.map(\.id) == savedIDs && restored.allSatisfy { active.videoDurationRange!.contains($0.durationSeconds) }, "all 30 restored works retain known matching metadata despite reversed response ordering")
        let restoredStore = FeedStore()
        restoredStore.restoreTimeline(items: restored, identity: restoreSource.feedIdentity, filter: active, followed: false, continuation: savedContinuation, blockedTags: [])
        check(restoredStore.items.map(\.id) == savedIDs && restoredStore.unverifiedDuration == 0 && !restoredStore.reachedEnd, "duration policy retains all 30 works including the saved source tail")
        check(restoredStore.continuationSnapshot(windowIDs: savedIDs, capturedAt: savedContinuation.capturedAt) == savedContinuation, "full duration metadata coverage preserves exact saved continuation")

        let cancelRestore = DurationSource(), cancelSecondStarted = DurationGate(), releaseCancelSecond = DurationGate()
        cancelRestore.durationFetch = {
            let ids = cancelRestore.lastIDs
            if cancelRestore.metadataCalls == 2 { cancelSecondStarted.open(); await releaseCancelSecond.wait() }
            return ids.map { .init(id: $0, metadata: .init(duration: 130)) }
        }
        let cancelledRestore = Task { try await cancelRestore.enrichRestoredVideoDurations(savedItems, filter: active, isCurrent: { true }) }
        await cancelSecondStarted.wait()
        cancelledRestore.cancel(); releaseCancelSecond.open()
        do {
            _ = try await cancelledRestore.value
            check(false, "cancelled second restore batch must reject the entire restored window")
        } catch is CancellationError {
            check(cancelRestore.metadataCalls == 2, "cancellation across two batches rejects rather than returning a partially enriched window")
        }

        let changedRestore = DurationSource(), changedSecondStarted = DurationGate(), releaseChangedSecond = DurationGate()
        let restoreIdentity = changedRestore.feedIdentity
        changedRestore.durationFetch = {
            let ids = changedRestore.lastIDs
            if changedRestore.metadataCalls == 2 { changedSecondStarted.open(); await releaseChangedSecond.wait() }
            return ids.map { .init(id: $0, metadata: .init(duration: 140)) }
        }
        let accountRestore = Task { try await changedRestore.enrichRestoredVideoDurations(savedItems, filter: active, isCurrent: { changedRestore.feedIdentity == restoreIdentity }) }
        await changedSecondStarted.wait()
        changedRestore.feedIdentity = "fixture:new-account"; releaseChangedSecond.open()
        do {
            _ = try await accountRestore.value
            check(false, "account change in second restore batch must reject the entire restored window")
        } catch is CancellationError {
            check(changedRestore.metadataCalls == 2, "account change across two batches cannot mix accounts or return partial restoration")
        }
        print("VideoDurationChecks: \(checks) checks passed")
    }
}
