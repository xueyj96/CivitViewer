import Foundation

@main struct TimelineStateChecks {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1; precondition(condition(), message)
        }
        func media(_ id: Int, _ url: String, type: String? = "image", creatorID: Int? = nil,
                   username: String? = "fixture") -> MediaItem {
            .init(id: id, url: url, width: 720, height: nil, type: type,
                  username: username, browsingLevel: 1, thumbnail: nil, creatorID: creatorID)
        }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let filter = FeedFilter(kind: .image)
        let base = TimelineCheckpoint(lane: .recommendation, filter: filter, ids: [1, 2, 3], focusedID: 2, updatedAt: now)
        var changedTimestamp = base; changedTimestamp.updatedAt = now.addingTimeInterval(600)
        changedTimestamp.ids = [2, 3, 4]
        let signature = TimelineStatePolicy.dismissalSignature(owner: "owner-A", lane: .recommendation, checkpoint: base)
        check(signature == TimelineStatePolicy.dismissalSignature(owner: "owner-A", lane: .recommendation, checkpoint: changedTimestamp),
              "Logical dismissal signature ignores exposure timestamp and changing window IDs for the same focus and filter")
        var changedFocus = changedTimestamp; changedFocus.focusedID = 3
        check(signature != TimelineStatePolicy.dismissalSignature(owner: "owner-A", lane: .recommendation, checkpoint: changedFocus),
              "A different logical focus is independently eligible")
        check(signature != TimelineStatePolicy.dismissalSignature(owner: "owner-B", lane: .recommendation, checkpoint: base), "Dismissal is isolated by owner")
        check(signature != TimelineStatePolicy.dismissalSignature(owner: "owner-A", lane: .following, checkpoint: base), "Dismissal is isolated by lane")
        check(signature != TimelineStatePolicy.dismissalSignature(owner: "owner-A", lane: .recommendation,
              checkpoint: TimelineCheckpoint(lane: .recommendation, filter: FeedFilter(kind: .video), ids: [1,2], focusedID: 2, updatedAt: now)),
              "Different filters form a different resume scope")

        let suite = "TimelineStateChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "fixture.dismissals"
        let recommendation = TimelineCheckpointDismissals(defaults: defaults, key: key)
        check(!recommendation.contains(owner: "owner-A", lane: .recommendation, checkpoint: base), "A new local dismissal store has no consumed checkpoint")
        recommendation.dismiss(owner: "owner-A", lane: .recommendation, checkpoint: base)
        check(TimelineCheckpointDismissals(defaults: defaults, key: key).contains(owner: "owner-A", lane: .recommendation, checkpoint: changedTimestamp),
              "Consumed logical focus stays dismissed across timestamp and window updates and reconstruction")
        let nextFocus = TimelineCheckpointDismissals(defaults: defaults, key: key)
        check(!nextFocus.contains(owner: "owner-A", lane: .recommendation, checkpoint: changedFocus), "A different focus remains a new offer")

        let following = TimelineCheckpoint(lane: .following, filter: filter, ids: [8], focusedID: 8, updatedAt: now)
        TimelineCheckpointDismissals(defaults: defaults, key: key).dismiss(owner: "owner-A", lane: .following, checkpoint: following)
        let restoredDismissals = TimelineCheckpointDismissals(defaults: defaults, key: key)
        check(restoredDismissals.contains(owner: "owner-A", lane: .recommendation, checkpoint: base), "Interleaved lane writes preserve recommendation dismissal")
        check(restoredDismissals.contains(owner: "owner-A", lane: .following, checkpoint: following), "Interleaved lane writes preserve following dismissal")

        let legacyKey = "fixture.legacy28"
        let legacySignature = "owner-A|recommendation|\(String(now.timeIntervalSince1970.bitPattern, radix: 16))|2"
        defaults.set([legacySignature], forKey: legacyKey)
        let legacyDismissals = TimelineCheckpointDismissals(defaults: defaults, key: legacyKey)
        check(legacyDismissals.contains(owner: "owner-A", lane: .recommendation, checkpoint: changedTimestamp),
              "Build 28 timestamp-based dismissal remains honored for its owner, lane and logical focus")
        check(!legacyDismissals.contains(owner: "owner-A", lane: .following, checkpoint: following), "Legacy dismissal does not cross lanes")

        let capKey = "fixture.cap"
        let capped = TimelineCheckpointDismissals(defaults: defaults, key: capKey)
        for id in 1...120 {
            capped.dismiss(owner: "owner-A", lane: .recommendation,
                           checkpoint: TimelineCheckpoint(lane: .recommendation, filter: filter, ids: [id], focusedID: id, updatedAt: now))
        }
        check((defaults.stringArray(forKey: capKey)?.count ?? 0) == 100, "Logical dismissals remain bounded at 100 signatures")

        let sourceTail = 3
        check(TimelineStatePolicy.continuationCoversLoadedTail(windowIDs: [1,2,3], sourceTailID: sourceTail), "A checkpoint retaining the loaded tail can preserve its cursor")
        check(!TimelineStatePolicy.continuationCoversLoadedTail(windowIDs: [1,2], sourceTailID: sourceTail), "A truncated checkpoint cannot skip the uncovered continuation gap")
        let continuation = TimelineContinuation(cursor: "eyJvZmZzZXQiOjQyfQ", capturedAt: now, reachedEnd: false)
        check(continuation != nil, "A bounded opaque cursor is accepted")
        check(TimelineContinuation(cursor: "https://example.invalid/cursor", capturedAt: now, reachedEnd: false) == nil, "URL cursors are rejected")
        check(TimelineContinuation(cursor: "bad\nvalue", capturedAt: now, reachedEnd: false) == nil, "Control characters in cursors are rejected")
        check(TimelineContinuation(cursor: String(repeating: "x", count: 8_193), capturedAt: now, reachedEnd: false) == nil, "Cursor byte size is bounded")
        check(TimelineContinuation(cursor: nil, capturedAt: now, reachedEnd: true) != nil && TimelineContinuation(cursor: nil, capturedAt: now, reachedEnd: false) == nil,
              "Only reached-end snapshots may omit a cursor")
        let snapshot = TimelineCheckpoint(lane: .following, filter: FeedFilter(kind: .video), ids: [3,4], focusedID: 4, updatedAt: now, continuation: continuation)
        let roundTrip = try JSONDecoder().decode(TimelineCheckpoint.self, from: JSONEncoder().encode(snapshot))
        check(roundTrip == snapshot, "Optional continuation round-trips without changing checkpoint schema")
        let legacyJSON = #"{"lane":"recommendation","filter":{"kind":"all","sort":"Most Reactions","period":"Week","baseModel":"","onlyPG":false},"ids":[1,2],"focusedID":2,"updatedAt":1800000000}"#
        let legacySnapshot = try JSONDecoder().decode(TimelineCheckpoint.self, from: Data(legacyJSON.utf8))
        check(legacySnapshot.continuation == nil, "Schema-1 checkpoint without continuation remains readable")

        let asset = "1B8CB1F8-AC2B-4E7D-93D0-0D2BF22F3BA1"
        let url720 = "https://image.civitai.com/token/\(asset)/width=720/a.webp"
        let url1080 = "https://image.civitai.com/token/\(asset)/width=1080/a.webp"
        var nilType = media(10, url720, type: nil)
        let explicitImage = media(11, url1080, type: "image")
        check(nilType.isSupported && nilType.mediaAssetKey == explicitImage.mediaAssetKey, "Missing type keeps supported image asset identity")
        nilType.type = "video"
        check(nilType.mediaAssetKey != explicitImage.mediaAssetKey, "Media asset identity remains type-scoped")

        let blockedIDs: Set<Int> = [7]
        let blockedHandles: Set<String> = ["unique"]
        check(AuthorHandlePolicy.blocks(creatorID: 7, username: "different", blockedIDs: blockedIDs, blockedHandles: blockedHandles), "Known blocked ID wins over a different reported handle")
        check(!AuthorHandlePolicy.blocks(creatorID: 99, username: "unique", blockedIDs: blockedIDs, blockedHandles: blockedHandles), "Known nonblocked ID never falls back to a matching handle")
        check(AuthorHandlePolicy.blocks(creatorID: nil, username: " UNIQUE ", blockedIDs: blockedIDs, blockedHandles: blockedHandles), "Missing ID uses canonical unique handle policy")
        check(!AuthorHandlePolicy.blocks(creatorID: nil, username: nil, blockedIDs: blockedIDs, blockedHandles: blockedHandles), "Anonymous media remains visible")
        let nilAuthor = media(30, "https://example.invalid/30", creatorID: nil, username: " Alice ")
        check(AuthorHandlePolicy.followingUsernamesNeedingResolution([nilAuthor, media(31, "https://example.invalid/31", username: "alice")]) == ["Alice"],
              "Following author resolution deduplicates normalized canonical names")
        check(AuthorHandlePolicy.attachingFollowingCreatorIDs([nilAuthor], resolved: [Creator(id: 77, username: "alice", image: nil)], followingIDs: [77]).first?.creatorID == 77,
              "Only a unique resolved author inside the current follow set attaches")
        check(AuthorHandlePolicy.attachingFollowingCreatorIDs([nilAuthor], resolved: [Creator(id: 77, username: "alice", image: nil), Creator(id: 78, username: "ALICE", image: nil)], followingIDs: [77,78]).first?.creatorID == nil,
              "Ambiguous normalized author handles do not attach an ID")

        var feed = FeedAccumulator(deduplicateMediaAssets: true)
        feed.append(.init(items: [media(40, url720, type: nil)], metadata: .init(nextCursor: "p2")))
        feed.append(.init(items: [explicitImage], metadata: .init(nextCursor: nil)))
        check(feed.items.map(\.id) == [40] && feed.duplicateCount == 1, "Continuation preserves cross-page asset deduplication")
        feed.applyBlockedAuthors(ids: blockedIDs, handles: blockedHandles)
        feed.applyBlockedAuthors(ids: [], handles: [])
        check(feed.items.map(\.id) == [40] && feed.reachedEnd, "Pure author filtering retains source items and continuation state")

        print("TimelineStateChecks: \(checks) assertions passed")
    }
}
