import Foundation

@MainActor private final class PublicationFixture: PublicationSource {
    var feedIdentity = "fixture-A"
    var calls = 0, concurrent = 0, peak = 0
    var fail = false, changeIdentity = false
    func latestPublication(creator: Creator) async throws -> PublicationResult {
        calls += 1; concurrent += 1; peak = max(peak, concurrent)
        defer { concurrent -= 1 }
        try await Task.sleep(for: .milliseconds(2))
        if changeIdentity { feedIdentity = "fixture-B" }
        if fail { throw URLError(.timedOut) }
        return .published(Date())
    }
}

@main struct BrowsingChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ reason: String) {
            precondition(condition, reason); checks += 1
        }
        let key = "CivitViewer.BrowsingChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: key)!
        defer { defaults.removePersistentDomain(forName: key) }
        let tags = TagBlocklist(defaults: defaults)
        check(tags.names.isEmpty, "No default block tags")
        check(tags.add("  FuTa \n") && tags.names == ["futa"], "Normalize case and edge whitespace")
        check(tags.add("ＦＵＴＡ") && tags.names.count == 1, "Compatibility forms deduplicate")
        check(!tags.add(" \n") && !tags.add(String(repeating: "x", count: 81)), "Reject empty or oversized tags")
        check(TagBlocklist(defaults: defaults).names == ["futa"], "Persist across instances")
        tags.remove(" FUTA ")
        check(TagBlocklist(defaults: defaults).names.isEmpty, "Removal persists")
        check(TagPolicy.verdict(names: nil, blocked: []) == .allowed, "No policy does not hide missing tags")
        check(TagPolicy.verdict(names: nil, blocked: ["futa"]) == .unverified, "Missing metadata is not a confirmed negative")
        check(TagPolicy.verdict(names: [], blocked: ["futa"]) == .allowed, "Explicit empty tag response is known")
        check(TagPolicy.verdict(names: ["futa"], blocked: ["futa"]) == .blocked, "Actual exact tag blocks")
        check(TagPolicy.verdict(names: ["futanari"], blocked: ["futa"]) == .allowed, "No invented synonyms")
        for kind in MediaKind.allCases {
            for context in [FilterContext.discovery, .following, .creator] {
                let reset = FeedFilter(kind: kind, sort: "Most Comments", period: "Day", baseModel: "SDXL 1.0", onlyPG: true).resetting(in: context)
                check(reset == FeedFilter.defaults(for: context, kind: kind), "Reset preserves current media type and uses the correct browsing context")
            }
        }
        let legacy = OfflineRecord(id: 1, video: true, username: "fixture", creatorID: 7, browsingLevel: 1, collectionIDs: [1], cloudState: .saved)
        let legacyData = try JSONEncoder().encode(legacy)
        let restored = try JSONDecoder().decode(OfflineRecord.self, from: legacyData)
        check(restored.id == legacy.id && restored.tagNames == nil, "Old offline indexes restore without new tag metadata")
        var tagged = legacy; tagged.tagNames = ["landscape"]
        let taggedData = try JSONEncoder().encode(tagged)
        let taggedRestored = try JSONDecoder().decode(OfflineRecord.self, from: taggedData)
        check(taggedRestored.media(in: URL(fileURLWithPath: "/tmp/fixture")).tagNames == ["landscape"], "Tag metadata survives offline restore without storing source URLs")
        func media(_ tags: String) throws -> MediaItem {
            try JSONDecoder().decode(MediaItem.self, from: Data("{\"id\":1,\"url\":\"https://example.com/fixture\",\"type\":\"image\",\"tags\":\(tags)}".utf8))
        }
        check(try media("[{\"id\":1}]").tagNames == nil, "Tag IDs without names are unknown")
        check(try media("[]").tagNames == [], "Explicit empty metadata remains known")
        check(try media("[{\"id\":1,\"name\":\" FuTa \"}]").tagNames == ["futa"], "Remote tag names use the same normalization as preferences")

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        check(RecentPublication.week.includes(now.addingTimeInterval(-7 * 86_400), now: now), "Inclusive rolling boundary")
        check(!RecentPublication.week.includes(now.addingTimeInterval(-7 * 86_400 - 1), now: now), "Older outside range")
        check(!RecentPublication.any.includes(now.addingTimeInterval(1), now: now), "Future publication is not current")
        func page(_ posts: String = "", cursor: String = "null") throws -> PublicationPage {
            try JSONDecoder().decode(PublicationPage.self, from: Data("{\"items\":[\(posts)],\"nextCursor\":\(cursor)}".utf8))
        }
        func post(owner: Int = 7, date: String = "2026-10-24T12:00:00.123Z", type: String = "video") -> String {
            "{\"id\":1,\"publishedAt\":\"\(date)\",\"user\":{\"id\":\(owner)},\"images\":[{\"type\":\"\(type)\"}]}"
        }
        let expectedDate = ISO8601DateFormatter().date(from: "2026-10-24T12:00:00Z")!.addingTimeInterval(0.123)
        var scan = PublicationScan(creatorID: 7)
        let publication = scan.consume(try page(post()), now: now)
        if case .published(let date) = publication { check(abs(date.timeIntervalSince(expectedDate)) < 0.001, "Use publication timestamp with fractional seconds") }
        else { preconditionFailure("Expected a verified publication date") }
        scan = PublicationScan(creatorID: 7)
        check(scan.consume(try page(cursor: "123"), now: now) == nil, "Empty page with numeric cursor continues")
        check(scan.consume(try page(cursor: "123"), now: now) == .unverified, "Repeated cursor is unknown")
        scan = PublicationScan(creatorID: 7)
        check(scan.consume(try page(), now: now) == .noVisibleWorks, "Complete empty response is scoped negative")
        scan = PublicationScan(creatorID: 7)
        check(scan.consume(try page(post(owner: 8)), now: now) == .unverified, "Wrong owner cannot supply activity proof")
        scan = PublicationScan(creatorID: 7)
        check(scan.consume(try page(post(date: "invalid")), now: now) == .unverified, "Invalid date is unknown")
        scan = PublicationScan(creatorID: 7)
        check(scan.consume(try page(post(date: "2099-10-24T12:00:00Z")), now: now) == .unverified, "Scheduled future work is unknown")
        scan = PublicationScan(creatorID: 7)
        check(scan.consume(try page(post(type: "new-format")), now: now) == .unverified, "New media format is not no work")
        scan = PublicationScan(creatorID: 7)
        check(scan.consume(try page(post(type: "audio"), cursor: "\"opaque\""), now: now) == nil, "Audio-only post does not stand in for visual work")
        check(scan.consume(try page(post(date: "2026-10-25T12:00:00Z")), now: now) == .unverified, "Out-of-order pages cannot prove most recent visual date")

        let authors = (1...45).map { Creator(id: $0, username: "fixture-\($0)", image: nil) }
        let source = PublicationFixture(), activity = CreatorActivityStore()
        await activity.checkNext(authors, source: source)
        check(source.calls == 40 && source.peak <= 3 && activity.checks.count == 40 && !activity.busy, "One batch at most 40 authors, concurrency at most three")
        await activity.checkNext(authors, source: source)
        check(source.calls == 45 && activity.checks.count == 45, "Progressive batch fills uncovered authors")
        await activity.checkNext(authors, source: source)
        check(source.calls == 45, "Fresh checks reuse ten-minute cache")
        check(activity.result(for: 1, now: Date().addingTimeInterval(601)) == nil, "Expired results return to unknown")
        source.feedIdentity = "changed"; source.fail = true
        await activity.checkNext([authors[0]], source: source)
        check(activity.checks.count == 1 && activity.result(for: 1) == .unverified, "Account/range identity discards old cache; request failure is unknown")
        let before = source.calls
        await activity.checkNext([authors[0]], source: source)
        check(source.calls == before, "Unknown results do not retry automatically forever")
        source.fail = false
        await activity.checkNext([authors[0]], source: source, retryUnknown: true)
        check(activity.result(for: 1) != .unverified && source.calls == before + 1, "Explicit retry resolves unknown")
        source.feedIdentity = "new-A"; source.changeIdentity = true
        await activity.checkNext(Array(authors.prefix(4)), source: source)
        check(activity.checks.isEmpty && !activity.busy, "Identity changes during requests reject stale results")
        source.changeIdentity = false; source.feedIdentity = "cancel"
        let task = Task { await activity.checkNext(authors, source: source) }
        task.cancel(); await task.value
        check(activity.checks.isEmpty && !activity.busy, "Cancellation cannot publish stale activity")

        let failureCases: [VideoFailure] = [.http(404), .http(410), .http(403), .http(401), .http(429), .http(500), .network, .unknown, .decoderMissing, .localMissing]
        check(failureCases.allSatisfy { VideoRecoveryPolicy.decide(failed: false, failure: $0, recoveryAttempted: true) == .wait }, "Loading and buffering never skip, regardless of elapsed time")
        check(VideoRecoveryPolicy.decide(failed: true, failure: .http(404), recoveryAttempted: false) == .recover, "First 404 gets fresh-address recovery")
        check([VideoFailure.http(404), .http(410), .http(403), .http(500), .decoderMissing, .network, .unknown].allSatisfy { VideoRecoveryPolicy.decide(failed: true, failure: $0, recoveryAttempted: true) == .skip }, "A confirmed failed retry may try the next work without declaring this one permanently absent")
        check([VideoFailure.http(401), .http(429)].allSatisfy { failure in
            [false, true].allSatisfy { VideoRecoveryPolicy.decide(failed: true, failure: failure, recoveryAttempted: $0) == .manualRetry }
        }, "Authentication and rate limits stop without a retry or skip storm")
        check(VideoRecoveryPolicy.decide(failed: true, failure: .localMissing, recoveryAttempted: false) == .skip, "Actually missing local file is terminal without deletion")
        var advance = PlaybackAdvanceState()
        check(advance.target(failedID: 1, focused: 2, ids: [1,2,3], active: true) == nil && advance.target(failedID: 1, focused: 1, ids: [1,2,3], active: false) == nil, "Inactive/stale failure never moves current page")
        let ids = Array(1...9)
        for id in 1...3 { check(advance.target(failedID: id, focused: id, ids: ids, active: true) == id + 1, "Confirmed failure advances once to the next attempt"); advance.focusChanged(id + 1) }
        check(advance.target(failedID: 4, focused: 4, ids: ids, active: true) == nil && advance.consecutive == 3, "At most three following works are tried before stopping for user control")
        advance.focusChanged(8)
        check(advance.target(failedID: 8, focused: 8, ids: ids, active: true) == 9, "Manual navigation resets finite skip budget")
        advance = PlaybackAdvanceState()
        check(advance.target(failedID: 1, focused: 1, ids: [1], active: true) == nil, "No next item preserves current failure for pagination")
        check(advance.target(failedID: 1, focused: 1, ids: [1,2], active: true) == 2 && advance.target(failedID: 1, focused: 1, ids: [1,2], active: true) == nil, "New page allows one deferred advance; duplicate callback ignored")
        check(MediaFocusPolicy.target(current: 2, previousIDs: [1,2], ids: [1,2,3]) == 2, "Background prefetch does not move a valid current item")
        check(MediaFocusPolicy.target(current: -1, previousIDs: [1,2], ids: [1,2,3,4]) == 3, "Continue-loading page advances to first newly appended work, not the first old work")
        check(MediaFocusPolicy.target(current: -1, previousIDs: [1,2], ids: [1,2]) == -1, "Empty continuation preserves load-more state")
        check(MediaFocusPolicy.target(current: 2, previousIDs: [1,2,3,4], ids: [1,4]) == 4, "Filtered current item moves forward to the next retained work")
        check(MediaFocusPolicy.target(current: nil, previousIDs: [], ids: [5,6]) == 5, "Initial result selects the first actual item")
        check(MediaFocusPolicy.target(current: 2, previousIDs: [1,2], ids: []) == nil, "Empty result cannot keep a stale focused item")
        let nextIntent = MediaContinuationIntent(anchorID: 2, context: "account-A:queue-1:focus-0")
        check(nextIntent.target(focused: 2, ids: [1,2], context: nextIntent.context, active: true) == nil,
              "An explicit next-item intent cannot manufacture a missing work")
        check(nextIntent.target(focused: 2, ids: [1,2,3,4], context: nextIntent.context, active: true) == 3,
              "A requested continuation picks the first available next work, not the previous or final work")
        check(nextIntent.target(focused: 1, ids: [1,2,3], context: nextIntent.context, active: true) == nil &&
              nextIntent.target(focused: 2, ids: [1,2,3], context: nextIntent.context, active: false) == nil,
              "Back navigation and hidden viewers reject a stale next-item intent")
        check(["account-B:queue-1:focus-0", "account-A:queue-2:focus-0", "account-A:queue-1:focus-1"].allSatisfy {
            nextIntent.target(focused: 2, ids: [1,2,3], context: $0, active: true) == nil
        }, "Account, filter queue, and explicit focus changes cannot adopt old continuation intent")
        check(nextIntent.target(focused: 2, ids: [1,3], context: nextIntent.context, active: true) == nil,
              "A removed anchor cannot move focus backward or select an unrelated new work")
        print("BrowsingChecks: \(checks) policy and publication checks passed")
    }
}
