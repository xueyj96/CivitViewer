import Foundation

/// FakeTimelineSource implements the production reading capabilities. Production
/// FeedStore, MediaRead, TimelineModel and BrowsingHistory run against temporary data.
@MainActor final class FakeTimelineSource: TimelineReading {
    struct PageRequest { let filter: FeedFilter; let cursor: String?; let followed: Bool }
    var account: Account? = Account(id: 700, username: "fixture", browsingLevel: 31, blurNsfw: false)
    var tagLibraryOwnerID: Int? = 700
    var feedIdentity = "fixture-account-700"
    var followingMemberIDs = Set<Int>()
    var pageRequests: [PageRequest] = []
    var mediaBatches: [[Int]] = []
    var creatorLookups: [String] = []
    var mediaByID: [Int: MediaItem] = [:]
    var creatorsByName: [String: Creator] = [:]
    var mediaError: Error?
    var pageError: Error?
    var mediaStarted: TestGate?
    var mediaRelease: TestGate?
    var mediaAfterAwait: (@MainActor () -> Void)?
    var fetch: (PageRequest) async throws -> MediaPage = { _ in .init(items: [], metadata: .init(nextCursor: nil)) }

    func mediaPage(filter: FeedFilter, cursor: String?, creator: Creator?, followed: Bool, includeTags: Bool) async throws -> MediaPage {
        let request = PageRequest(filter: filter, cursor: cursor, followed: followed)
        pageRequests.append(request)
        if let pageError { throw pageError }
        return try await fetch(request)
    }
    func collectionPage(id: Int, filter: FeedFilter, cursor: String?, allAccessibleLevels: Bool, includeTags: Bool) async throws -> MediaPage {
        try await mediaPage(filter: filter, cursor: cursor, creator: nil, followed: false, includeTags: includeTags)
    }
    func searchMediaPage(target: MediaSearchTarget, filter: FeedFilter, cursor: String?, includeTags: Bool) async throws -> MediaPage {
        try await mediaPage(filter: filter, cursor: cursor, creator: nil, followed: false, includeTags: includeTags)
    }
    func mediaItems(ids: [Int], includeTags: Bool) async throws -> [MediaItem] {
        mediaBatches.append(ids)
        if let mediaStarted { mediaStarted.open() }
        if let mediaRelease { await mediaRelease.wait() }
        mediaAfterAwait?()
        if let mediaError { throw mediaError }
        return ids.compactMap { mediaByID[$0] }
    }
    func creator(username: String) async throws -> Creator {
        creatorLookups.append(username)
        guard let creator = creatorsByName[AuthorHandlePolicy.normalize(username)] else { throw ClientError.missingCreator }
        return creator
    }
}

@MainActor final class TestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait(file: StaticString = #filePath, line: UInt = #line) async {
        guard !opened else { return }
        let deadline = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            preconditionFailure("Fixture gate was never opened", file: file, line: line)
        }
        await withCheckedContinuation { continuation = $0 }
        deadline.cancel()
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

@main struct TimelineModelChecks {
    @MainActor static func main() async throws {
        var checks = 0
        var temporarySuites: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1; precondition(condition(), message)
            FileHandle.standardError.write(Data("CHECK \(checks): \(message)\n".utf8))
        }
        func media(_ id: Int, type: String = "image", creatorID: Int? = 7,
                   username: String? = "fixture", tags: [String] = []) -> MediaItem {
            MediaItem(id: id, url: "https://example.invalid/work/\(id)", width: 640, height: 480, type: type,
                      username: username, browsingLevel: 1, thumbnail: nil, creatorID: creatorID,
                      tags: tags.map { MediaTag(name: $0) })
        }
        func tempSuite(_ prefix: String) -> (String, UserDefaults) {
            let name = "TimelineModelChecks.\(prefix).\(UUID().uuidString)"
            temporarySuites.append(name)
            return (name, UserDefaults(suiteName: name)!)
        }
        func seed(_ root: URL, owner: Int, checkpoint: TimelineCheckpoint) async throws {
            let writer = BrowsingHistory(rootURL: root)
            await writer.bind(ownerID: owner, identity: "seed-\(UUID().uuidString)")
            let context = writer.context(ownerID: owner)!
            writer.checkpoint(checkpoint, context: context)
            await writer.waitForWrites()
            precondition(writer.checkpoints.contains(where: { $0.focusedID == checkpoint.focusedID }), "Seed archive checkpoint committed")
        }
        func modelAndSession(root: URL, owner: Int, followed: Bool = false, filter: FeedFilter = FeedFilter(),
                             authors: AuthorBlocklist? = nil, defaults: UserDefaults? = nil,
                             now: @escaping @MainActor () -> Date = { Date() },
                             slicePause: (@MainActor (Int) async throws -> Void)? = nil) async ->
            (TimelineModel, BrowsingHistory, FakeTimelineSource, AuthorBlocklist, UserDefaults) {
            let history = BrowsingHistory(rootURL: root)
            await history.bind(ownerID: owner, identity: "test-session-\(UUID().uuidString)")
            let suite = defaults ?? tempSuite("model").1
            let authorStore = authors ?? AuthorBlocklist(defaults: suite, key: "authors")
            let prefs = tempSuite("feed").1
            prefs.set(true, forKey: "deduplicateMedia")
            let feed = slicePause.map { FeedStore(preferences: prefs, authorBlocks: authorStore, now: now, slicePause: $0) }
                ?? FeedStore(preferences: prefs, authorBlocks: authorStore, now: now)
            let dismissals = TimelineCheckpointDismissals(defaults: suite, key: "dismissals")
            let model = TimelineModel(followed: followed, filter: filter, feed: feed, history: history,
                                      authors: authorStore, dismissals: dismissals)
            let session = FakeTimelineSource()
            session.tagLibraryOwnerID = owner
            session.feedIdentity = "fixture-account-\(owner)"
            if followed { session.followingMemberIDs = [7] }
            return (model, history, session, authorStore, suite)
        }

        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workspace)
            for suite in temporarySuites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        }

        // Offer capture is per BrowsingHistory process facade. Dismissal is
        // persistent and logical, so checkpoint writes do not recreate the offer.
        let offerRoot = workspace.appendingPathComponent("offer", isDirectory: true)
        let firstCheckpoint = TimelineCheckpoint(lane: .recommendation, filter: FeedFilter(kind: .image), ids: [1,2,3], focusedID: 2,
                                                 updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try await seed(offerRoot, owner: 700, checkpoint: firstCheckpoint)
        let (_, dismissDefaults) = tempSuite("dismiss")
        let (model1, history1, _, authors1, _) = await modelAndSession(root: offerRoot, owner: 700, defaults: dismissDefaults)
        model1.bindHistory(ownerID: 700)
        check(model1.resumeCandidate?.focusedID == 2, "A checkpoint persisted before first bind becomes the resume offer")
        model1.dismissPrompt()
        check(model1.resumeCandidate == nil && model1.promptRevision == 1, "Closing the prompt consumes the offer immediately")
        let context1 = history1.context(ownerID: 700)!
        history1.record(media(2, type: "video"), context: context1,
                        checkpoint: TimelineCheckpoint(lane: .recommendation, filter: firstCheckpoint.filter,
                                                       ids: [1,2,3], focusedID: 2,
                                                       updatedAt: firstCheckpoint.updatedAt.addingTimeInterval(30)))
        await history1.waitForWrites()
        check(history1.records.contains(where: { $0.id == 2 }) && history1.checkpoints.first?.updatedAt != firstCheckpoint.updatedAt,
              "Real history record and checkpoint writes continue after dismissal")
        check(model1.resumeCandidate == nil, "New timestamp and window data do not reoffer the dismissed logical focus")
        let rebuiltModel = TimelineModel(followed: false, history: history1, authors: authors1,
                                         dismissals: TimelineCheckpointDismissals(defaults: dismissDefaults, key: "dismissals"))
        rebuiltModel.bindHistory(ownerID: 700)
        check(rebuiltModel.resumeCandidate == nil, "Model reconstruction against the same process baseline does not recreate a dismissed offer")
        await history1.bind(ownerID: 700, identity: "same-owner-new-session")
        check(rebuiltModel.resumeCandidate == nil, "Same-owner rebind preserves the original resume baseline and consumed signature")

        // A new process captures the then-current logical focus. Same focus
        // remains consumed; a genuinely different focus may be offered.
        let process2 = BrowsingHistory(rootURL: offerRoot)
        await process2.bind(ownerID: 700, identity: "new-process-same-focus")
        let sameFocusModel = TimelineModel(followed: false, history: process2, authors: authors1,
                                           dismissals: TimelineCheckpointDismissals(defaults: dismissDefaults, key: "dismissals"))
        sameFocusModel.bindHistory(ownerID: 700)
        check(sameFocusModel.resumeCandidate == nil, "New process still honors the consumed same focus")
        let context2 = process2.context(ownerID: 700)!
        process2.checkpoint(TimelineCheckpoint(lane: .recommendation, filter: firstCheckpoint.filter, ids: [2,3,4], focusedID: 3,
                                               updatedAt: firstCheckpoint.updatedAt.addingTimeInterval(60)), context: context2)
        await process2.waitForWrites()
        let process3 = BrowsingHistory(rootURL: offerRoot)
        await process3.bind(ownerID: 700, identity: "new-process-different-focus")
        let changedFocusModel = TimelineModel(followed: false, history: process3, authors: authors1,
                                              dismissals: TimelineCheckpointDismissals(defaults: dismissDefaults, key: "dismissals"))
        changedFocusModel.bindHistory(ownerID: 700)
        check(changedFocusModel.resumeCandidate?.focusedID == 3, "A different logical focus can become a new process offer")

        // Legacy v28 signatures and shared two-lane/capped persistence.
        let legacyCheckpoint = TimelineCheckpoint(lane: .recommendation, filter: .defaults(for: .discovery), ids: [8], focusedID: 8,
                                                   updatedAt: Date(timeIntervalSince1970: 1_800_000_111))
        let legacySignature = "\(BrowsingHistory.key(700))|recommendation|\(String(legacyCheckpoint.updatedAt.timeIntervalSince1970.bitPattern, radix: 16))|8"
        dismissDefaults.set([legacySignature], forKey: "legacy")
        let legacyDismissals = TimelineCheckpointDismissals(defaults: dismissDefaults, key: "legacy")
        check(legacyDismissals.contains(owner: BrowsingHistory.key(700), lane: .recommendation, checkpoint: legacyCheckpoint),
              "A build 28 timestamp signature still hides its original logical focus")
        let interleave = "TimelineModelChecks.lanes.\(UUID().uuidString)"
        let laneDefaults = UserDefaults(suiteName: interleave)!
        defer { laneDefaults.removePersistentDomain(forName: interleave) }
        let recDismissals = TimelineCheckpointDismissals(defaults: laneDefaults, key: "lanes")
        let followDismissals = TimelineCheckpointDismissals(defaults: laneDefaults, key: "lanes")
        let modelFilter = FeedFilter(kind: .image)
        let rec = TimelineCheckpoint(lane: .recommendation, filter: modelFilter, ids: [20], focusedID: 20, updatedAt: Date())
        let follow = TimelineCheckpoint(lane: .following, filter: modelFilter, ids: [21], focusedID: 21, updatedAt: Date())
        recDismissals.dismiss(owner: "owner", lane: .recommendation, checkpoint: rec)
        followDismissals.dismiss(owner: "owner", lane: .following, checkpoint: follow)
        let laneReadback = TimelineCheckpointDismissals(defaults: laneDefaults, key: "lanes")
        check(laneReadback.contains(owner: "owner", lane: .recommendation, checkpoint: rec) && laneReadback.contains(owner: "owner", lane: .following, checkpoint: follow),
              "Interleaved recommendation/following dismissals do not overwrite each other")
        for id in 1...120 {
            recDismissals.dismiss(owner: "owner", lane: .recommendation,
                                  checkpoint: TimelineCheckpoint(lane: .recommendation, filter: modelFilter, ids: [id], focusedID: id, updatedAt: Date()))
        }
        check((laneDefaults.stringArray(forKey: "lanes")?.count ?? 0) <= 100, "Shared dismissal storage remains capped at 100 entries")

        // Actual model restore applies current tag and author policy atomically.
        let restoreRoot = workspace.appendingPathComponent("restore-success", isDirectory: true)
        let restoreFilter = FeedFilter(kind: .image)
        let restoreCheckpoint = TimelineCheckpoint(lane: .recommendation, filter: restoreFilter, ids: [31,32,33], focusedID: 33,
                                                    updatedAt: Date(timeIntervalSince1970: 1_800_000_222))
        try await seed(restoreRoot, owner: 701, checkpoint: restoreCheckpoint)
        let suiteSuccess = tempSuite("restore-success")
        defer { suiteSuccess.1.removePersistentDomain(forName: suiteSuccess.0) }
        let blockedAuthors = AuthorBlocklist(defaults: suiteSuccess.1, key: "authors")
        check(blockedAuthors.add(Creator(id: 44, username: "blocked", image: nil)), "Temporary author fixture is configured")
        let (successModel, successHistory, successSession, _, _) = await modelAndSession(root: restoreRoot, owner: 701,
            filter: FeedFilter(kind: .video), authors: blockedAuthors, defaults: suiteSuccess.1)
        successSession.fetch = { request in
            .init(items: [media(90, type: request.filter.kind == .video ? "video" : "image")], metadata: .init(nextCursor: nil))
        }
        successSession.mediaByID = [31: media(31, tags: ["hidden"]), 32: media(32, creatorID: 44, username: "blocked"), 33: media(33)]
        await successModel.activate(session: successSession, visible: true, blockedTags: ["hidden"])
        successModel.focused = 90
        check(successModel.feed.items.map(\.id) == [90] && successModel.filter.kind == .video, "Ordinary feed is loaded before restore")
        await successModel.restore(restoreCheckpoint, session: successSession)
        check(successModel.feed.items.map(\.id) == [33] && successModel.focused == 33 && successModel.filter == restoreFilter,
              "Restore atomically applies current tag/author filters, saved filter and checkpoint focus")
        check(successModel.focusRequest == 1 && successModel.restoreState.checkpoint == restoreCheckpoint,
              "Successful restore requests a new focus and enters the resumed state")
        check(successModel.resumeCandidate == nil && successHistory.checkpoints.contains(where: { $0.focusedID == 33 }),
              "Restore consumes the offer while preserving its persisted checkpoint")

        // Saved cursor failure is distinct from a legacy no-cursor rescan.
        let cursorRoot = workspace.appendingPathComponent("saved-cursor", isDirectory: true)
        let cursorToken = TimelineContinuation(cursor: "opaque-saved-cursor", capturedAt: Date(), reachedEnd: false)!
        let cursorCheckpoint = TimelineCheckpoint(lane: .recommendation, filter: restoreFilter, ids: [61,62], focusedID: 62,
                                                  updatedAt: Date(), continuation: cursorToken)
        try await seed(cursorRoot, owner: 704, checkpoint: cursorCheckpoint)
        let (cursorModel, _, cursorSession, _, _) = await modelAndSession(root: cursorRoot, owner: 704)
        cursorSession.fetch = { _ in .init(items: [media(90)], metadata: .init(nextCursor: nil)) }
        cursorSession.mediaByID = [61: media(61), 62: media(62)]
        await cursorModel.activate(session: cursorSession, visible: true, blockedTags: [])
        await cursorModel.restore(cursorCheckpoint, session: cursorSession)
        check(cursorModel.restoreState == .resumed(cursorCheckpoint, .savedCursor), "A valid saved cursor restores as a direct continuation")
        check(!cursorModel.shouldFillOnAppearance, "Saved-cursor restore remains page-gated on appearance")
        cursorSession.pageError = URLError(.timedOut)
        await cursorModel.next(session: cursorSession)
        check(cursorModel.feed.items.map(\.id) == [61,62] && cursorModel.restoreState == .resumed(cursorCheckpoint, .unavailable),
              "Saved-cursor failure retains restored rows and becomes explicitly unavailable")
        let callsAfterCursorFailure = cursorSession.pageRequests.count
        await cursorModel.next(session: cursorSession)
        await cursorModel.nextAutomatically(session: cursorSession)
        await cursorModel.fillUpcoming(session: cursorSession)
        check(cursorSession.pageRequests.count == callsAfterCursorFailure, "Unavailable cursor is not retried indefinitely")

        let (continuedModel, _, continuedSession, _, _) = await modelAndSession(root: cursorRoot, owner: 704)
        continuedSession.fetch = { _ in .init(items: [media(90)], metadata: .init(nextCursor: nil)) }
        continuedSession.mediaByID = [61: media(61), 62: media(62)]
        await continuedModel.activate(session: continuedSession, visible: true, blockedTags: [])
        await continuedModel.restore(cursorCheckpoint, session: continuedSession)
        check(!continuedModel.shouldFillOnAppearance && continuedModel.restoreState == .resumed(cursorCheckpoint, .savedCursor),
              "Restored saved-cursor queue remains excluded from appearance fill")
        continuedSession.pageRequests = []
        var continuedPage = 0
        continuedSession.fetch = { _ in
            continuedPage += 1
            return .init(items: [media(62 + continuedPage)], metadata: .init(nextCursor: "continued:\(continuedPage)"))
        }
        await continuedModel.next(session: continuedSession)
        check(continuedModel.feed.items.map(\.id) == [61,62,63], "Explicit page action advances the restored cursor first")
        await continuedModel.fillUpcoming(session: continuedSession)
        check(continuedModel.feed.items.map(\.id) == Array(61...68) && continuedSession.pageRequests.count == 6 &&
              !continuedModel.shouldFillOnAppearance,
              "Explicit post-page fill continues restored cursor and preserves the appearance gate")

        let monthMinuteFilter = FeedFilter(kind: .video, sort: "Most Reactions", period: "Month",
            videoDurationRange: VideoDurationRange(minimumSeconds: 60, maximumSeconds: nil))
        func minuteVideo(_ id: Int, duration: Double?) -> MediaItem {
            var value = media(id, type: "video")
            value.metadata = duration.map { VideoTechnicalMetadata(duration: $0) }
            return value
        }
        for combined in [false, true] {
            let singleRoot = workspace.appendingPathComponent("month-minute-single-\(combined)")
            let singleCheckpoint = TimelineCheckpoint(lane: .recommendation, filter: monthMinuteFilter,
                ids: [960], focusedID: 960, updatedAt: Date(),
                continuation: TimelineContinuation(cursor: "month-minute-saved", capturedAt: Date(), reachedEnd: false)!)
            try await seed(singleRoot, owner: 790, checkpoint: singleCheckpoint)
            let (singleModel, _, singleSession, _, _) = await modelAndSession(root: singleRoot, owner: 790, filter: monthMinuteFilter)
            let original = minuteVideo(960, duration: 60)
            singleSession.fetch = { _ in .init(items: [original], metadata: .init(nextCursor: "start")) }
            singleSession.mediaByID = [960: original]
            await singleModel.activate(session: singleSession, visible: true, blockedTags: [])
            await singleModel.restore(singleCheckpoint, session: singleSession)
            check(singleModel.feed.items.map(\.id) == [960] && !singleModel.shouldFillOnAppearance,
                  "A single saved long-video queue retains the no-appearance-rescan contract")
            singleSession.pageRequests = []
            let focusRequest = singleModel.focusRequest, queueRevision = singleModel.queueRevision
            var page = 0, matched = 0
            singleSession.fetch = { request in
                precondition(request.filter == monthMinuteFilter)
                page += 1
                let candidate: MediaItem
                if (page - 1).isMultiple(of: 9) {
                    matched += 1
                    candidate = minuteVideo(960 + matched, duration: matched.isMultiple(of: 2) ? 300 : 60)
                } else if page.isMultiple(of: 3) { candidate = original }
                else { candidate = minuteVideo(10_000 + page, duration: page.isMultiple(of: 2) ? nil : 59.9) }
                return .init(items: [candidate], metadata: .init(nextCursor: "month-minute:\(page)"))
            }
            if combined { await singleModel.nextAndFillUpcoming(session: singleSession) }
            else { await singleModel.next(session: singleSession) }
            if combined {
                check(singleModel.feed.items.map(\.id) == Array(960...966) && singleSession.pageRequests.count == 46,
                      "One explicit viewer continuation crosses46 sparse duration pages and fills six future60s/300s videos")
                check(singleModel.feed.unverifiedDuration > 0 && singleModel.feed.hiddenByDuration > 0 && singleModel.feed.duplicatesDiscarded > 0,
                      "Unknown duration,59.9s and duplicates never count toward the six-work reserve")
            } else {
                check(singleModel.feed.items.map(\.id) == [960,961] && singleSession.pageRequests.count == 1,
                      "The old single-page viewer action reproduces only one future match for the same saved queue")
            }
            check(singleModel.focused == 960 && singleModel.focusRequest == focusRequest && singleModel.queueRevision == queueRevision &&
                  singleModel.filter == monthMinuteFilter && !singleModel.shouldFillOnAppearance,
                  "Explicit reserve fill preserves focus,query,and restored appearance gate")
        }

        let rescanRoot = workspace.appendingPathComponent("legacy-rescan", isDirectory: true)
        let rescanCheckpoint = TimelineCheckpoint(lane: .recommendation, filter: restoreFilter, ids: [71,72], focusedID: 72, updatedAt: Date())
        try await seed(rescanRoot, owner: 705, checkpoint: rescanCheckpoint)
        let (rescanModel, _, rescanSession, _, _) = await modelAndSession(root: rescanRoot, owner: 705)
        rescanSession.fetch = { _ in .init(items: [media(72), media(73)], metadata: .init(nextCursor: nil)) }
        rescanSession.mediaByID = [71: media(71), 72: media(72)]
        await rescanModel.activate(session: rescanSession, visible: true, blockedTags: [])
        await rescanModel.restore(rescanCheckpoint, session: rescanSession)
        check(rescanModel.restoreState == .resumed(rescanCheckpoint, .rescanPending), "Legacy checkpoint without cursor announces upstream rescan")
        check(!rescanModel.shouldFillOnAppearance, "Legacy rescan restore remains page-gated on appearance")
        await rescanModel.nextAutomatically(session: rescanSession)
        check(rescanModel.feed.items.map(\.id) == [71,72,73] && rescanModel.feed.reachedEnd,
              "Legacy rescan starts from upstream beginning, skips restored duplicate IDs and appends later work")

        // A failed read consumes only the prompt; the normal list, focus and filter remain intact.
        let failureRoot = workspace.appendingPathComponent("restore-failure", isDirectory: true)
        try await seed(failureRoot, owner: 702, checkpoint: restoreCheckpoint)
        let (failureModel, failureHistory, failureSession, _, _) = await modelAndSession(root: failureRoot, owner: 702, filter: FeedFilter(kind: .video))
        failureSession.fetch = { _ in .init(items: [media(90, type: "video")], metadata: .init(nextCursor: nil)) }
        await failureModel.activate(session: failureSession, visible: true, blockedTags: [])
        failureModel.focused = 90
        failureSession.mediaError = URLError(.timedOut)
        await failureModel.restore(restoreCheckpoint, session: failureSession)
        check(failureModel.feed.items.map(\.id) == [90] && failureModel.focused == 90 && failureModel.filter.kind == .video,
              "Failed restore leaves ordinary rows, focus and filter untouched")
        check(failureModel.messageIsError && failureModel.resumeCandidate == nil && failureHistory.checkpoints.count == 1,
              "Failed restore closes the hint, reports an error, and preserves the checkpoint")

        // Restore pending A, switch to B and load it. Releasing A must not replace B.
        let switchRoot = workspace.appendingPathComponent("restore-switch-filter", isDirectory: true)
        try await seed(switchRoot, owner: 703, checkpoint: restoreCheckpoint)
        let (switchModel, _, switchSession, _, _) = await modelAndSession(root: switchRoot, owner: 703, filter: FeedFilter(kind: .video))
        switchSession.fetch = { request in .init(items: [media(90, type: request.filter.kind == .video ? "video" : "image")], metadata: .init(nextCursor: nil)) }
        switchSession.mediaByID = [31: media(31), 32: media(32), 33: media(33)]
        await switchModel.activate(session: switchSession, visible: true, blockedTags: [])
        switchModel.focused = 90
        let started = TestGate(), release = TestGate()
        switchSession.mediaStarted = started; switchSession.mediaRelease = release
        let pendingRestore = Task { await switchModel.restore(restoreCheckpoint, session: switchSession) }
        await started.wait()
        let filterB = FeedFilter(kind: .image, onlyPG: true)
        switchModel.selectFilter(filterB)
        switchSession.mediaRelease = nil
        await switchModel.activate(session: switchSession, visible: true, blockedTags: [], force: true)
        release.open(); await pendingRestore.value
        check(switchModel.filter == filterB && switchModel.feed.items.map(\.id) == [90] && switchModel.focused == 90,
              "A late restore for filter A cannot overwrite an activated filter B")

        // Account identity, following membership, hidden state and task cancellation
        // each invalidate the same staged restore ticket.
        for event in ["account", "following", "hidden", "cancel"] {
            let root = workspace.appendingPathComponent("interrupt-\(event)", isDirectory: true)
            let owner = 710 + (event == "account" ? 0 : event == "following" ? 1 : event == "hidden" ? 2 : 3)
            let lane = event == "following" ? HistoryLane.following : .recommendation
            let checkpoint = TimelineCheckpoint(lane: lane, filter: restoreFilter, ids: [41], focusedID: 41, updatedAt: Date())
            try await seed(root, owner: owner, checkpoint: checkpoint)
            let (interruptModel, _, interruptSession, _, interruptDefaults) = await modelAndSession(root: root, owner: owner, followed: event == "following", filter: FeedFilter())
            interruptSession.fetch = { _ in .init(items: [media(90)], metadata: .init(nextCursor: nil)) }
            interruptSession.mediaByID[41] = media(41, creatorID: event == "following" ? nil : 7,
                                                    username: event == "following" ? "alice" : "fixture")
            interruptSession.creatorsByName["alice"] = Creator(id: 7, username: "Alice", image: nil)
            await interruptModel.activate(session: interruptSession, visible: true, blockedTags: [])
            let startedGate = TestGate(), releaseGate = TestGate()
            interruptSession.mediaStarted = startedGate; interruptSession.mediaRelease = releaseGate
            let restoreTask = Task { await interruptModel.restore(checkpoint, session: interruptSession) }
            await startedGate.wait()
            switch event {
            case "account":
                interruptSession.feedIdentity = "changed-account"
                interruptModel.invalidateSession()
            case "following":
                interruptSession.followingMemberIDs = [99]
                await interruptModel.followingChanged([99], session: interruptSession)
            case "hidden":
                interruptModel.setVisible(false)
            case "cancel":
                restoreTask.cancel()
            default: break
            }
            releaseGate.open(); await restoreTask.value
            check(!interruptModel.feed.items.contains(where: { $0.id == 41 }) && interruptModel.restoreState != .resumed(checkpoint, .rescanPending),
                  "Stale (event) restore completion cannot commit checkpoint rows")
            _ = interruptDefaults
        }

        // Following restore uses the production MediaRead path to resolve a nil
        // ID once per canonical handle before the current membership filter.
        let followingRoot = workspace.appendingPathComponent("following-hydration", isDirectory: true)
        let followingCheckpoint = TimelineCheckpoint(lane: .following, filter: restoreFilter, ids: [51,52], focusedID: 52, updatedAt: Date())
        try await seed(followingRoot, owner: 720, checkpoint: followingCheckpoint)
        let (followingModel, _, followingSession, _, followingDefaults) = await modelAndSession(root: followingRoot, owner: 720, followed: true)
        defer { followingDefaults.removePersistentDomain(forName: "") }
        followingSession.fetch = { _ in .init(items: [media(90)], metadata: .init(nextCursor: nil)) }
        followingSession.followingMemberIDs = [7]
        followingSession.mediaByID = [51: media(51, creatorID: nil, username: "alice"), 52: media(52, creatorID: nil, username: " Alice ")]
        followingSession.creatorsByName["alice"] = Creator(id: 7, username: "Alice", image: nil)
        await followingModel.activate(session: followingSession, visible: true, blockedTags: [])
        await followingModel.restore(followingCheckpoint, session: followingSession)
        check(followingSession.creatorLookups == ["alice"] && followingModel.feed.items.map(\.id) == [51,52],
              "Following restore reuses MediaRead canonical resolution and validates both nil-ID works; lookups=\(followingSession.creatorLookups), ids=\(followingModel.feed.items.map(\.id)), state=\(followingModel.restoreState)")

        // A single tab tap repositions within each lane. It must never read a
        // new page, discard a continuation or change the lane's current filter.
        for followed in [false, true] {
            let topRoot = workspace.appendingPathComponent("return-to-top-\(followed)", isDirectory: true)
            let selectedFilter = FeedFilter(kind: followed ? .video : .image, sort: "Newest", period: "AllTime")
            let (topModel, _, topSession, _, _) = await modelAndSession(root: topRoot, owner: followed ? 726 : 725,
                                                                        followed: followed, filter: selectedFilter)
            let topItems = [141, 142, 143].map { media($0, type: followed ? "video" : "image") }
            topSession.fetch = { _ in .init(items: topItems, metadata: .init(nextCursor: "keep-this-continuation")) }
            await topModel.activate(session: topSession, visible: true, blockedTags: [])
            topModel.focused = 143
            let queue = topModel.feed.items, requests = topSession.pageRequests.count
            let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
            let continuation = topModel.feed.continuationSnapshot(windowIDs: queue.map(\.id), capturedAt: capturedAt)
            let focusRequest = topModel.focusRequest, queueRevision = topModel.queueRevision
            topModel.scrollToStart()
            check(topModel.focused == 141 && topModel.focusRequest == focusRequest + 1,
                  "Single tab tap explicitly positions the first loaded work in each lane")
            check(topSession.pageRequests.count == requests && topModel.feed.items == queue && topModel.queueRevision == queueRevision,
                  "Single tab tap performs no read and preserves the exact loaded queue")
            check(topModel.filter == selectedFilter && topModel.followed == followed &&
                  topModel.feed.continuationSnapshot(windowIDs: queue.map(\.id), capturedAt: capturedAt) == continuation,
                  "Single tab tap retains the current source, filter and continuation")
            check(!topModel.automaticLoadingAllowed, "Returning to top suppresses focus-triggered automatic paging")
            check(!topModel.shouldFillOnAppearance, "Returning to top suppresses appearance-driven fill")
            await topModel.nextAutomatically(session: topSession)
            check(topSession.pageRequests.count == requests && topModel.focused == 141 && !topModel.automaticLoadingAllowed,
                  "Automatic demand cannot release the return-to-top gate even for a short queue")
            topModel.focused = 142
            check(topModel.automaticLoadingAllowed, "Moving away from programmatic top restores ordinary automatic paging")
            topModel.focused = 143; topModel.setVisible(false); topModel.scrollToStart()
            check(topModel.focused == 143, "An inactive lane ignores another lane's return-to-top action")
        }

        // Restarting from a resumed checkpoint is a transactional new first
        // page: it retains the user's filter/source and persisted history, but
        // replaces the visible queue and cursor only after a successful read.
        let restartRoot = workspace.appendingPathComponent("restart-success", isDirectory: true)
        let restartCheckpoint = TimelineCheckpoint(lane: .recommendation, filter: FeedFilter(kind: .video, sort: "Newest", period: "AllTime"),
                                                   ids: [81,82], focusedID: 82, updatedAt: Date())
        try await seed(restartRoot, owner: 730, checkpoint: restartCheckpoint)
        let restartDefaults = tempSuite("restart-success").1
        let (restartModel, restartHistory, restartSession, _, _) = await modelAndSession(root: restartRoot, owner: 730,
            filter: FeedFilter(kind: .image, sort: "Most Comments", period: "Month"), defaults: restartDefaults)
        restartSession.fetch = { request in
            if request.cursor == nil && request.filter.kind == .image {
                return .init(items: [media(101), media(102)], metadata: .init(nextCursor: "old-page-2"))
            }
            return .init(items: [media(103, type: "video")], metadata: .init(nextCursor: "fresh-page-2"))
        }
        restartSession.mediaByID = [81: media(81, type: "video"), 82: media(82, type: "video")]
        await restartModel.activate(session: restartSession, visible: true, blockedTags: [])
        restartModel.focused = 102
        await restartModel.restore(restartCheckpoint, session: restartSession)
        check(restartModel.restoreState == .resumed(restartCheckpoint, .rescanPending) && restartModel.filter == restartCheckpoint.filter,
              "From-head restart fixture begins in the actual resumed state")
        restartSession.pageRequests.removeAll()
        let checkpointCountBeforeRestart = restartHistory.checkpoints.count
        await restartModel.restartFromStart(session: restartSession)
        let restartRequest = restartSession.pageRequests.first
        check(restartRequest?.cursor == nil && restartRequest?.filter == restartCheckpoint.filter && restartRequest?.followed == false,
              "From-head restart requests cursor nil with the saved filter and discovery source")
        check(restartModel.feed.items.map(\.id) == [103] && restartModel.focused == 103 && restartModel.focusRequest == 2,
              "Successful restart replaces the resumed queue and focuses its first result")
        check(restartModel.queueRevision == 1 && restartModel.feed.continuationSnapshot(windowIDs: [103])?.cursor == "fresh-page-2",
              "Successful restart advances queue revision and installs only the new continuation")
        check(restartHistory.checkpoints.count == checkpointCountBeforeRestart && restartHistory.checkpoints.contains(where: { $0.focusedID == 82 }),
              "Restart leaves the persisted history checkpoint intact")

        // A failed staged restart preserves the exact visible queue, focus,
        // continuation and queue revision. A later retry can commit normally.
        let retainRoot = workspace.appendingPathComponent("restart-failure-retry", isDirectory: true)
        var retainClock = Date()
        try await seed(retainRoot, owner: 731, checkpoint: restartCheckpoint)
        let (retainModel, _, retainSession, _, _) = await modelAndSession(root: retainRoot, owner: 731,
            filter: FeedFilter(kind: .image, sort: "Most Reactions", period: "Week"), now: { retainClock })
        var returnRetryPage = false
        retainSession.fetch = { request in
            if returnRetryPage { return .init(items: [media(113)], metadata: .init(nextCursor: "retry-cursor")) }
            if request.cursor == nil && request.filter.kind == .image {
                return .init(items: [media(111), media(112)], metadata: .init(nextCursor: "retained-cursor"))
            }
            return .init(items: [media(113, type: "video")], metadata: .init(nextCursor: "retry-cursor"))
        }
        await retainModel.activate(session: retainSession, visible: true, blockedTags: [])
        retainModel.focused = 112
        let retainedIDs = retainModel.feed.items.map(\.id)
        let retainedContinuation = retainModel.feed.continuationSnapshot(windowIDs: retainedIDs, capturedAt: Date(timeIntervalSince1970: 1234))
        let retainedRevision = retainModel.queueRevision
        retainSession.pageError = URLError(.timedOut)
        await retainModel.restartFromStart(session: retainSession)
        let retainedContinuationAfterFailure = retainModel.feed.continuationSnapshot(windowIDs: retainedIDs, capturedAt: Date(timeIntervalSince1970: 1234))
        check(retainModel.feed.items.map(\.id) == retainedIDs && retainModel.focused == 112 &&
              retainedContinuationAfterFailure == retainedContinuation && retainModel.queueRevision == retainedRevision,
              "Failed restart retains exact old rows, focus, continuation and queue revision")
        check(retainModel.messageIsError && retainModel.notice?.recovery == .restartFromStart,
              "Failed restart exposes a retryable error notice")
        let retainedRequestsAfterFailure = retainSession.pageRequests.count
        await retainModel.nextAutomatically(session: retainSession)
        check(retainSession.pageRequests.count == retainedRequestsAfterFailure && retainModel.focused == 112 &&
              retainModel.feed.items.map(\.id) == retainedIDs && retainModel.pagingMode.isWaitingForExplicitAction,
              "Background continuation cannot release a failed restart's explicit-wait gate or alter retained focus")
        retainSession.pageError = nil
        returnRetryPage = true
        await retainModel.restartFromStart(session: retainSession)
        check(retainSession.pageRequests.count == retainedRequestsAfterFailure && retainModel.pagingMode.isWaitingForExplicitAction,
              "Model refresh attempts during staged cooldown send no repeated HTTP requests")
        retainClock = retainClock.addingTimeInterval(60)
        await retainModel.restartFromStart(session: retainSession)
        check(retainModel.feed.items.map(\.id) == [113] && retainModel.focused == 113 && retainModel.queueRevision == retainedRevision + 1,
              "Retry after failure commits a fresh first page; got ids=\(retainModel.feed.items.map(\.id)) focus=\(String(describing: retainModel.focused)) revision=\(retainModel.queueRevision) state=\(retainModel.restoreState) cursors=\(retainSession.pageRequests.map(\.cursor))")

        // UI double taps are coalesced while the production request is gated;
        // both calls share one upstream first-page request and the waiter still
        // commits its focus after the response arrives.
        let coalesceRoot = workspace.appendingPathComponent("restart-coalesce", isDirectory: true)
        try await seed(coalesceRoot, owner: 732, checkpoint: restartCheckpoint)
        let (coalesceModel, _, coalesceSession, _, _) = await modelAndSession(root: coalesceRoot, owner: 732,
            filter: FeedFilter(kind: .image))
        let requestStarted = TestGate(), requestRelease = TestGate()
        coalesceSession.fetch = { _ in
            requestStarted.open(); await requestRelease.wait()
            return .init(items: [media(121)], metadata: .init(nextCursor: nil))
        }
        coalesceModel.setVisible(true)
        coalesceModel.requestRestartFromStart(session: coalesceSession)
        await requestStarted.wait()
        coalesceModel.requestRestartFromStart(session: coalesceSession)
        coalesceModel.requestRestartFromStart(session: coalesceSession)
        requestRelease.open()
        while coalesceModel.queueRevision == 0 { await Task.yield() }
        check(coalesceSession.pageRequests.count == 1 && coalesceModel.feed.items.map(\.id) == [121] &&
              coalesceModel.focused == 121 && coalesceModel.queueRevision == 1,
              "Repeated restart events during one gated request produce one HTTP read and keep its committing waiter")

        // Exactly two real timer waits: one verifies a successful legacy
        // (nil-continuation) restore notice expires without a redraw rearming
        // it; the other verifies an older info timer cannot erase a newer
        // persistent error event.
        let timerRoot = workspace.appendingPathComponent("notice-timers", isDirectory: true)
        let timerCheckpoint = TimelineCheckpoint(lane: .recommendation, filter: FeedFilter(kind: .image),
                                                  ids: [130], focusedID: 130, updatedAt: Date())
        try await seed(timerRoot, owner: 733, checkpoint: timerCheckpoint)
        let timerDefaults = tempSuite("notice-timers").1
        let (timerModel, _, timerSession, _, _) = await modelAndSession(root: timerRoot, owner: 733,
            filter: FeedFilter(kind: .image), defaults: timerDefaults)
        timerSession.fetch = { _ in .init(items: [media(131)], metadata: .init(nextCursor: nil)) }
        timerSession.mediaByID[130] = media(130)
        timerModel.setVisible(true)
        await timerModel.activate(session: timerSession, visible: true, blockedTags: [])
        await timerModel.restore(timerCheckpoint, session: timerSession)
        let infoID = timerModel.notice?.id
        check(timerModel.notice?.isError == false && infoID != nil && timerModel.restoreState == .resumed(timerCheckpoint, .rescanPending),
              "Successful nil-continuation restore creates an information notice")
        timerModel.focused = 130
        await timerModel.activate(session: timerSession, visible: true, blockedTags: [])
        check(timerModel.notice?.id == infoID, "Focus changes and redraw-like activation do not replace or renew the notice event")
        try await Task.sleep(for: .milliseconds(2700))
        check(timerModel.notice == nil, "Information notice expires at its original event deadline")

        await timerModel.restartFromStart(session: timerSession)
        let expiredInfoID = timerModel.notice?.id
        timerSession.pageError = URLError(.timedOut)
        await timerModel.restartFromStart(session: timerSession)
        let errorID = timerModel.notice?.id
        timerModel.clearMessage(id: expiredInfoID)
        check(timerModel.messageIsError && errorID != expiredInfoID, "Late clear for an older info event cannot clear the new error")
        try await Task.sleep(for: .milliseconds(2700))
        check(timerModel.messageIsError && timerModel.notice?.id == errorID, "An earlier timer does not expire a newer error notice")
        timerModel.clearMessage(id: errorID)
        check(timerModel.notice == nil, "The matching event ID can explicitly clear the current error")
        check(!timerModel.automaticLoadingAllowed && timerModel.pagingMode.isWaitingForExplicitAction,
              "Closing the refresh error does not silently authorize automatic retry")
        let requestsAfterClose = timerSession.pageRequests.count
        timerModel.setVisible(false)
        await timerModel.activate(session: timerSession, visible: true, blockedTags: [])
        check(!timerModel.automaticLoadingAllowed && timerSession.pageRequests.count == requestsAfterClose,
              "Returning to the same lane after closing an error keeps the old queue without automatic first-page retries")
        timerSession.pageError = nil
        await timerModel.restartFromStart(session: timerSession)
        check(timerModel.automaticLoadingAllowed && timerSession.pageRequests.count == requestsAfterClose + 1,
              "An explicit retry restarts once and restores automatic paging only after success")

        // Regression A: a first-page activation has configured the store but is
        // still in flight. A failed from-head transaction leaves the key in an
        // explicit-wait state; hiding and reopening the same lane cannot let
        // FeedStore.next bypass that wait merely because its load is incomplete.
        let incompleteRoot = workspace.appendingPathComponent("failed-restart-incomplete-store", isDirectory: true)
        var incompleteClock = Date()
        let (incompleteModel, _, incompleteSession, _, _) = await modelAndSession(root: incompleteRoot, owner: 737,
            filter: FeedFilter(kind: .image), now: { incompleteClock })
        let firstPageStarted = TestGate(), firstPageRelease = TestGate()
        var activationReadCount = 0
        incompleteSession.fetch = { _ in
            activationReadCount += 1
            if activationReadCount == 1 {
                firstPageStarted.open(); await firstPageRelease.wait()
                return .init(items: [], metadata: .init(nextCursor: "abandoned-page"))
            }
            return .init(items: [media(161)], metadata: .init(nextCursor: nil))
        }
        let incompleteActivation = Task {
            await incompleteModel.activate(session: incompleteSession, visible: true, blockedTags: [])
        }
        await firstPageStarted.wait()
        incompleteSession.pageError = URLError(.timedOut)
        await incompleteModel.restartFromStart(session: incompleteSession)
        let failedKey = FeedStoreRequestKey(identity: incompleteSession.feedIdentity,
            filter: FeedFilter(kind: .image), source: .discovery)
        check(incompleteModel.pagingMode.waitingKey == failedKey && incompleteModel.feed.items.isEmpty,
              "A failed restart records its key even while initial activation had not committed a page")
        firstPageRelease.open(); await incompleteActivation.value
        let readsAfterFailure = incompleteSession.pageRequests.count
        incompleteSession.pageError = nil
        incompleteModel.setVisible(false)
        await incompleteModel.activate(session: incompleteSession, visible: true, blockedTags: [])
        check(incompleteSession.pageRequests.count == readsAfterFailure && incompleteModel.feed.items.isEmpty &&
              !incompleteModel.feed.loading && incompleteModel.pagingMode.waitingKey == failedKey,
              "Reopening the same incomplete key does not start an implicit read or remain loading")
        incompleteClock = incompleteClock.addingTimeInterval(60)
        await incompleteModel.restartFromStart(session: incompleteSession)
        check(incompleteSession.pageRequests.count == readsAfterFailure + 1 && incompleteModel.feed.items.map(\.id) == [161] &&
              incompleteModel.automaticLoadingAllowed,
              "An explicit retry succeeds from the incomplete store and re-enables normal loading")

        // Regression B: after a failed direct restart on a fresh model, the
        // FeedStore has no requestKey at all. The model's failed key must still
        // suppress a same-context automatic activation until explicit retry.
        let unconfiguredRoot = workspace.appendingPathComponent("failed-restart-unconfigured-store", isDirectory: true)
        var unconfiguredClock = Date()
        let (unconfiguredModel, _, unconfiguredSession, _, _) = await modelAndSession(root: unconfiguredRoot, owner: 738,
            filter: FeedFilter(kind: .video), now: { unconfiguredClock })
        unconfiguredSession.fetch = { _ in .init(items: [media(171, type: "video")], metadata: .init(nextCursor: nil)) }
        unconfiguredModel.setVisible(true)
        unconfiguredSession.pageError = URLError(.timedOut)
        await unconfiguredModel.restartFromStart(session: unconfiguredSession)
        let unconfiguredKey = FeedStoreRequestKey(identity: unconfiguredSession.feedIdentity,
            filter: FeedFilter(kind: .video), source: .discovery)
        check(unconfiguredModel.feed.requestKey == nil && unconfiguredModel.pagingMode.waitingKey == unconfiguredKey,
              "A failed direct restart is remembered even though FeedStore never configured a request key")
        let requestsAfterDirectFailure = unconfiguredSession.pageRequests.count
        unconfiguredSession.pageError = nil
        await unconfiguredModel.activate(session: unconfiguredSession, visible: true, blockedTags: [])
        check(unconfiguredSession.pageRequests.count == requestsAfterDirectFailure && unconfiguredModel.feed.items.isEmpty &&
              !unconfiguredModel.feed.loading && !unconfiguredModel.automaticLoadingAllowed,
              "Same-key activation after an unconfigured failure does not auto-retry or stick in loading")
        unconfiguredClock = unconfiguredClock.addingTimeInterval(60)
        await unconfiguredModel.restartFromStart(session: unconfiguredSession)
        check(unconfiguredSession.pageRequests.count == requestsAfterDirectFailure + 1 &&
              unconfiguredModel.feed.items.map(\.id) == [171] && unconfiguredModel.automaticLoadingAllowed,
              "Explicit retry after an unconfigured failure loads the queue successfully")

        // A gated restart cannot write its stale first page after the active
        // filter changes; activation of the new filter owns the visible queue.
        let staleRoot = workspace.appendingPathComponent("restart-filter-change", isDirectory: true)
        let (staleModel, _, staleSession, _, _) = await modelAndSession(root: staleRoot, owner: 734,
            filter: FeedFilter(kind: .image))
        let staleStarted = TestGate(), staleRelease = TestGate()
        staleSession.fetch = { request in
            if request.filter.kind == .image {
                staleStarted.open(); await staleRelease.wait()
                return .init(items: [media(141)], metadata: .init(nextCursor: nil))
            }
            return .init(items: [media(142, type: "video")], metadata: .init(nextCursor: nil))
        }
        staleModel.setVisible(true)
        let staleRestart = Task { await staleModel.restartFromStart(session: staleSession) }
        await staleStarted.wait()
        let filterChanged = FeedFilter(kind: .video, onlyPG: true)
        staleModel.selectFilter(filterChanged)
        staleSession.fetch = { _ in .init(items: [media(142, type: "video")], metadata: .init(nextCursor: nil)) }
        await staleModel.activate(session: staleSession, visible: true, blockedTags: [], force: true)
        staleRelease.open(); await staleRestart.value
        check(staleModel.filter == filterChanged && staleModel.feed.items.map(\.id) == [142] && staleModel.focused == 142,
              "Late from-head result cannot overwrite the newly activated filter's first page")

        // Identity switch and hiding also invalidate a staged restart. Neither
        // late page is allowed to resurrect its old context after release.
        for event in ["identity", "hidden"] {
            let root = workspace.appendingPathComponent("restart-\(event)", isDirectory: true)
            let (model, _, session, _, _) = await modelAndSession(root: root, owner: event == "identity" ? 735 : 736,
                filter: FeedFilter(kind: .image))
            let started = TestGate(), release = TestGate()
            session.fetch = { _ in
                started.open(); await release.wait()
                return .init(items: [media(event == "identity" ? 151 : 152)], metadata: .init(nextCursor: nil))
            }
            model.setVisible(true)
            let pending = Task { await model.restartFromStart(session: session) }
            await started.wait()
            if event == "identity" {
                session.feedIdentity = "fixture-account-switched"
                model.invalidateSession()
            } else {
                model.setVisible(false)
            }
            release.open(); await pending.value
            check(model.feed.items.isEmpty && model.focused == nil && model.queueRevision == 0,
                  "Late restart page cannot commit after \(event) invalidates its operation")
        }

        // Cancellation of the model's creating task propagates through the
        // staged FeedStore task even when the source finishes after cancellation.
        let ownerCancelRoot = workspace.appendingPathComponent("model-restart-owner-cancel", isDirectory: true)
        let (ownerCancelModel, _, ownerCancelSession, _, _) = await modelAndSession(root: ownerCancelRoot, owner: 742,
            filter: FeedFilter(kind: .video))
        ownerCancelSession.fetch = { _ in .init(items: [media(201, type: "video")], metadata: .init(nextCursor: "model-owner-tail")) }
        await ownerCancelModel.activate(session: ownerCancelSession, visible: true, blockedTags: [])
        let ownerPageStarted = TestGate(), releaseOwnerPage = TestGate()
        var modelPageCancelled = false
        ownerCancelSession.pageRequests = []
        ownerCancelSession.fetch = { _ in
            ownerPageStarted.open(); await releaseOwnerPage.wait()
            modelPageCancelled = Task.isCancelled
            return .init(items: [media(202, type: "video")], metadata: .init(nextCursor: "late-model-page"))
        }
        let modelOwner = Task { await ownerCancelModel.restartFromStart(session: ownerCancelSession) }
        await ownerPageStarted.wait(); modelOwner.cancel(); releaseOwnerPage.open(); await modelOwner.value
        check(modelPageCancelled && ownerCancelModel.feed.items.map(\.id) == [201] && ownerCancelModel.focused == 201 &&
              ownerCancelModel.queueRevision == 0 && !ownerCancelModel.feed.continuationState.isLoading,
              "Direct model restart owner cancellation reaches the source and cannot install a late response")

        // The UI's retained restartAction is cancelled on lane hiding. Confirm
        // that its child sleep terminates, rather than leaving an orphan scan.
        let actionCancelRoot = workspace.appendingPathComponent("model-restart-action-cancel", isDirectory: true)
        let actionSliceStarted = TestGate(), actionSliceStopped = TestGate()
        let (actionCancelModel, _, actionCancelSession, _, _) = await modelAndSession(root: actionCancelRoot, owner: 743,
            filter: FeedFilter(kind: .video), slicePause: { _ in
                actionSliceStarted.open()
                do { try await Task.sleep(for: .seconds(5)) }
                catch { actionSliceStopped.open(); throw error }
            })
        actionCancelSession.fetch = { _ in .init(items: [media(211, type: "video")], metadata: .init(nextCursor: "action-old-tail")) }
        await actionCancelModel.activate(session: actionCancelSession, visible: true, blockedTags: [])
        var actionPages = 0
        actionCancelSession.fetch = { _ in
            actionPages += 1
            return .init(items: [media(211 + actionPages)], metadata: .init(nextCursor: "action-scan:\(actionPages)"))
        }
        actionCancelModel.requestRestartFromStart(session: actionCancelSession)
        await actionSliceStarted.wait()
        let actionCancelledAt = Date()
        actionCancelModel.setVisible(false)
        await actionSliceStopped.wait()
        check(Date().timeIntervalSince(actionCancelledAt) < 1 && actionPages == 4 &&
              actionCancelModel.feed.items.map(\.id) == [211] && actionCancelModel.focused == 211 && actionCancelModel.queueRevision == 0,
              "Cancelling retained restartAction on hide interrupts its slice and preserves the old visible queue")

        // Timeline callers share FeedStore's multi-slice owner while preserving
        // the selected lane/filter and the currently viewed item.
        for hideWhileWaiting in [false, true] {
            let scanRoot = workspace.appendingPathComponent("timeline-slices-\(hideWhileWaiting)", isDirectory: true)
            let sliceStarted = TestGate(), releaseSlice = TestGate()
            let selectedFilter = FeedFilter(kind: .video, sort: "Most Reactions", period: "Week")
            let (scanModel, _, scanSession, _, _) = await modelAndSession(root: scanRoot, owner: hideWhileWaiting ? 741 : 740,
                followed: true, filter: selectedFilter, slicePause: { _ in sliceStarted.open(); await releaseSlice.wait() })
            scanSession.fetch = { _ in .init(items: [media(181, type: "video")], metadata: .init(nextCursor: "scan:0")) }
            await scanModel.activate(session: scanSession, visible: true, blockedTags: [])
            scanModel.focused = 181
            var scanned = 0
            scanSession.pageRequests = []
            scanSession.fetch = { request in
                scanned += 1
                check(request.filter == selectedFilter && request.followed, "Automatic slices retain the exact followed source and sort/filter")
                return .init(items: [media(181 + scanned, type: scanned == 9 ? "video" : "image")],
                             metadata: .init(nextCursor: scanned == 9 ? nil : "scan:\(scanned)"))
            }
            let scanOwner = Task { await scanModel.nextAutomatically(session: scanSession) }
            await sliceStarted.wait()
            check(scanned == 4 && scanModel.feed.items.map(\.id) == [181] && scanModel.focused == 181 &&
                  scanModel.feed.continuationState == .scanning,
                  "A timeline keeps its visible queue and focus during a filtered scheduling slice")
            await scanModel.nextAutomatically(session: scanSession)
            check(scanned == 4, "A second automatic timeline demand cannot become a second scanner")
            if hideWhileWaiting { scanModel.setVisible(false) }
            releaseSlice.open(); await scanOwner.value
            if hideWhileWaiting {
                check(scanned == 4 && scanModel.feed.items.map(\.id) == [181] && scanModel.focused == 181 && !scanModel.feed.loading,
                      "Hiding a timeline cancels its slice owner before a fifth batch and preserves the current work")
                await scanModel.nextAutomatically(session: scanSession)
                check(scanned == 4, "A hidden lane cannot schedule another automatic slice")
            } else {
                check(scanned == 9 && scanModel.feed.items.map(\.id) == [181,190] && scanModel.focused == 181 && scanModel.feed.reachedEnd,
                      "A ninth-batch match appends without resetting timeline focus")
            }
        }

        // Model-owned fill publishes the initial work, then walks distinct
        // eligible pages until the requested upcoming reserve is satisfied.
        let fillRoot = workspace.appendingPathComponent("fill-six-pages", isDirectory: true)
        let (fillModel, _, fillSession, _, _) = await modelAndSession(root: fillRoot, owner: 780)
        fillSession.fetch = { _ in .init(items: [media(780)], metadata: .init(nextCursor: "initial")) }
        await fillModel.activate(session: fillSession, visible: true, blockedTags: [])
        fillSession.pageRequests = []
        let fillStarted = TestGate(), fillRelease = TestGate()
        var fillPage = 0
        fillSession.fetch = { _ in
            fillPage += 1
            if fillPage == 1 { fillStarted.open(); await fillRelease.wait() }
            return .init(items: [media(780 + fillPage)], metadata: .init(nextCursor: "fill-\(fillPage)"))
        }
        let filling = Task { await fillModel.fillUpcoming(session: fillSession) }
        await fillStarted.wait()
        check(fillModel.feed.items.map(\.id) == [780] && fillModel.focused == 780,
              "Initial focused work stays visible while upcoming fill waits")
        fillRelease.open(); await filling.value
        check(fillModel.feed.items.map(\.id) == Array(780...786) && fillSession.pageRequests.count == 6,
              "One matching item on each separated page fills six upcoming works after focus")

        let deficitRoot = workspace.appendingPathComponent("fill-deficit-two", isDirectory: true)
        let (deficitModel, _, deficitSession, _, _) = await modelAndSession(root: deficitRoot, owner: 781)
        deficitSession.fetch = { _ in .init(items: [media(781), media(782), media(783), media(784), media(785)], metadata: .init(nextCursor: "d:0")) }
        await deficitModel.activate(session: deficitSession, visible: true, blockedTags: [])
        deficitSession.fetch = { request in
            let page = Int(request.cursor?.split(separator: ":").last ?? "0") ?? 0
            return .init(items: [media(786 + page)], metadata: .init(nextCursor: "d:\(page + 1)"))
        }
        await deficitModel.fillUpcoming(session: deficitSession)
        check(deficitModel.feed.items.count == 7 && deficitModel.feed.items.suffix(2).map(\.id) == [786, 787],
              "An existing four-item upcoming reserve fetches only its two-item deficit")

        let filteredRoot = workspace.appendingPathComponent("fill-filtered-dedup", isDirectory: true)
        let (filteredModel, _, filteredSession, _, _) = await modelAndSession(root: filteredRoot, owner: 782, filter: FeedFilter(kind: .video))
        filteredSession.fetch = { _ in .init(items: [media(782, type: "video")], metadata: .init(nextCursor: "base")) }
        await filteredModel.activate(session: filteredSession, visible: true, blockedTags: ["blocked"])
        filteredSession.pageRequests = []
        var filteredPage = 0
        filteredSession.fetch = { _ in
            filteredPage += 1
            let item: MediaItem
            if filteredPage == 1 { item = media(782, type: "video") } // duplicate
            else if filteredPage == 2 { item = media(800, type: "video", tags: ["blocked"]) }
            else if filteredPage == 3 { item = media(801, type: "image") }
            else { item = media(800 + filteredPage, type: "video") }
            return .init(items: [item], metadata: .init(nextCursor: "f:\(filteredPage)"))
        }
        await filteredModel.fillUpcoming(session: filteredSession)
        check(filteredSession.pageRequests.count >= 8 && filteredModel.feed.items.count == 7 &&
              filteredModel.feed.items.allSatisfy { $0.type == "video" && !($0.tags ?? []).contains(where: { $0.name == "blocked" }) },
              "Duplicates, blocklisted and wrong-kind pages do not count toward fill")

        let errorRoot = workspace.appendingPathComponent("fill-error-retains", isDirectory: true)
        let (errorModel, _, errorSession, _, _) = await modelAndSession(root: errorRoot, owner: 783)
        errorSession.fetch = { _ in .init(items: [media(783)], metadata: .init(nextCursor: "base")) }
        await errorModel.activate(session: errorSession, visible: true, blockedTags: [])
        errorSession.pageRequests = []
        errorSession.fetch = { _ in .init(items: [media(784)], metadata: .init(nextCursor: "partial")) }
        let partialGate = TestGate(), partialRelease = TestGate()
        var partialPage = 0
        errorSession.fetch = { _ in
            partialPage += 1
            if partialPage == 2 { partialGate.open(); await partialRelease.wait(); throw ClientError.http(429) }
            return .init(items: [media(783 + partialPage)], metadata: .init(nextCursor: "p:\(partialPage)"))
        }
        let partialFill = Task { await errorModel.fillUpcoming(session: errorSession) }
        await partialGate.wait(); partialRelease.open(); await partialFill.value
        let retainedPartial = errorModel.feed.items.map(\.id)
        let readsAtFailure = errorSession.pageRequests.count
        await errorModel.fillUpcoming(session: errorSession)
        check(retainedPartial == [783, 784] && errorModel.feed.items.map(\.id) == retainedPartial &&
              errorSession.pageRequests.count == readsAtFailure,
              "Partial fill preserves published rows and cooldown failure does not auto-retry")

        let stalledRoot = workspace.appendingPathComponent("fill-stalled-cursor", isDirectory: true)
        let (stalledModel, _, stalledSession, _, _) = await modelAndSession(root: stalledRoot, owner: 787)
        stalledSession.fetch = { _ in .init(items: [media(787)], metadata: .init(nextCursor: "same-cursor")) }
        await stalledModel.activate(session: stalledSession, visible: true, blockedTags: [])
        stalledSession.fetch = { _ in .init(items: [media(788)], metadata: .init(nextCursor: "same-cursor")) }
        await stalledModel.fillUpcoming(session: stalledSession)
        check(stalledModel.feed.items.map(\.id) == [787, 788] && stalledModel.feed.error != nil,
              "Cursor stall stops fill while preserving the already published queue")

        let coalesceFillRoot = workspace.appendingPathComponent("fill-coalesced", isDirectory: true)
        let (coalesceFillModel, _, coalesceFillSession, _, _) = await modelAndSession(root: coalesceFillRoot, owner: 784)
        coalesceFillSession.fetch = { _ in .init(items: [media(784)], metadata: .init(nextCursor: "base")) }
        await coalesceFillModel.activate(session: coalesceFillSession, visible: true, blockedTags: [])
        coalesceFillSession.pageRequests = []
        let coalesceStarted = TestGate(), coalesceRelease = TestGate()
        var coalescePage = 0
        coalesceFillSession.fetch = { _ in
            coalescePage += 1
            if coalescePage == 1 { coalesceStarted.open(); await coalesceRelease.wait() }
            return .init(items: [media(784 + coalescePage)], metadata: .init(nextCursor: "c:\(coalescePage)"))
        }
        let ownerFill = Task { await coalesceFillModel.fillUpcoming(session: coalesceFillSession) }
        await coalesceStarted.wait()
        let coalescedWaiter = Task { await coalesceFillModel.fillUpcoming(session: coalesceFillSession, minimumUpcoming: 2) }
        await Task.yield(); coalescedWaiter.cancel()
        coalesceRelease.open(); await ownerFill.value; await coalescedWaiter.value
        check(coalesceFillSession.pageRequests.count == 6 && coalesceFillModel.feed.items.count == 7,
              "Concurrent fill demands coalesce and waiter cancellation leaves the model owner running")

        let promoteRoot = workspace.appendingPathComponent("fill-promoted-demand", isDirectory: true)
        let (promoteModel, _, promoteSession, _, _) = await modelAndSession(root: promoteRoot, owner: 794)
        promoteSession.fetch = { _ in .init(items: [media(794)], metadata: .init(nextCursor: "base")) }
        await promoteModel.activate(session: promoteSession, visible: true, blockedTags: [])
        promoteSession.pageRequests = []
        let promoteStarted = TestGate(), promoteRelease = TestGate(), largerJoined = TestGate()
        var promotePage = 0
        promoteSession.fetch = { _ in
            promotePage += 1
            if promotePage == 1 { promoteStarted.open(); await promoteRelease.wait() }
            return .init(items: [media(794 + promotePage)], metadata: .init(nextCursor: "p:\(promotePage)"))
        }
        let smallerFill = Task { await promoteModel.fillUpcoming(session: promoteSession, minimumUpcoming: 2) }
        await promoteStarted.wait()
        let largerFill = Task {
            largerJoined.open()
            await promoteModel.fillUpcoming(session: promoteSession, minimumUpcoming: 6)
        }
        await largerJoined.wait()
        promoteRelease.open(); await smallerFill.value; await largerFill.value
        check(promoteSession.pageRequests.count == 6 && promoteModel.feed.items.count == 7,
              "A larger joining reserve demand promotes the active owner without starting a second fill")

        let focusRoot = workspace.appendingPathComponent("fill-focus-moves", isDirectory: true)
        let (focusFillModel, _, focusFillSession, _, _) = await modelAndSession(root: focusRoot, owner: 785)
        focusFillSession.fetch = { _ in .init(items: [media(785), media(786)], metadata: .init(nextCursor: "base")) }
        await focusFillModel.activate(session: focusFillSession, visible: true, blockedTags: [])
        focusFillModel.focused = 785
        focusFillSession.pageRequests = []
        let focusStarted = TestGate(), focusRelease = TestGate()
        var focusPage = 0
        focusFillSession.fetch = { _ in
            focusPage += 1
            if focusPage == 1 { focusStarted.open(); await focusRelease.wait() }
            return .init(items: [media(786 + focusPage)], metadata: .init(nextCursor: "m:\(focusPage)"))
        }
        let movingFill = Task { await focusFillModel.fillUpcoming(session: focusFillSession) }
        await focusStarted.wait(); focusFillModel.focused = 786; focusRelease.open(); await movingFill.value
        check(focusFillModel.feed.items.count == 8 && focusFillModel.feed.items.last?.id == 792,
              "Fill rereads moved focus and tops up the current focus reserve")

        let hideRoot = workspace.appendingPathComponent("fill-hide-late", isDirectory: true)
        let (hideModel, _, hideSession, _, _) = await modelAndSession(root: hideRoot, owner: 786)
        hideSession.fetch = { _ in .init(items: [media(786)], metadata: .init(nextCursor: "base")) }
        await hideModel.activate(session: hideSession, visible: true, blockedTags: [])
        hideSession.pageRequests = []
        let hideStarted = TestGate(), hideRelease = TestGate()
        hideSession.fetch = { _ in hideStarted.open(); await hideRelease.wait(); return .init(items: [media(787)], metadata: .init(nextCursor: "late")) }
        let hiddenFill = Task { await hideModel.fillUpcoming(session: hideSession) }
        await hideStarted.wait(); hideModel.setVisible(false); hideRelease.open(); await hiddenFill.value
        check(hideModel.feed.items.map(\.id) == [786] && !hideModel.shouldFillOnAppearance,
              "Hide invalidates fill and a late response cannot append")

        let keyRoot = workspace.appendingPathComponent("fill-key-change-late", isDirectory: true)
        let (keyModel, _, keySession, _, _) = await modelAndSession(root: keyRoot, owner: 788, filter: FeedFilter(kind: .image))
        keySession.fetch = { _ in .init(items: [media(788, type: "image")], metadata: .init(nextCursor: "base")) }
        await keyModel.activate(session: keySession, visible: true, blockedTags: [])
        let keyStarted = TestGate(), keyRelease = TestGate()
        keySession.fetch = { request in
            if request.filter.kind == .image {
                keyStarted.open(); await keyRelease.wait()
                return .init(items: [media(789, type: "image")], metadata: .init(nextCursor: "old-key"))
            }
            return .init(items: [media(790, type: "video")], metadata: .init(nextCursor: nil))
        }
        let staleKeyFill = Task { await keyModel.fillUpcoming(session: keySession) }
        await keyStarted.wait()
        keyModel.selectFilter(FeedFilter(kind: .video))
        await keyModel.activate(session: keySession, visible: true, blockedTags: [])
        keyRelease.open(); await staleKeyFill.value
        check(keyModel.feed.items.map(\.id) == [790] && keyModel.filter.kind == .video,
              "Filter-key change invalidates fill and late old-key response cannot replace the new queue")

        check(fillModel.shouldFillOnAppearance,
              "Ordinary browsing exposes stable appearance-fill demand")
        print("TimelineModelChecks: \(checks) real-model assertions passed; FakeTimelineSource reads are fake")
    }
}
