import Foundation

@main struct BrowsingHistoryStoreChecks {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("civit-history-store-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BrowsingHistory(rootURL: root)
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); checks += 1
        }
        func media(_ id: Int, type: String = "image", level: Int? = 1, tags: [MediaTag]? = [], author: Int? = 7) -> MediaItem {
            MediaItem(id: id, url: "https://example.com/media", width: 100, height: 100, type: type, username: "Fixture", browsingLevel: level, thumbnail: nil, creatorID: author, tags: tags)
        }
        await store.bind(ownerID: 1, identity: "owner1-session1")
        let first = store.context(ownerID: 1)!
        expect(store.ready && store.context(ownerID: 2) == nil, "Only bound account obtains context")
        store.record(media(1), context: first); await store.waitForWrites()
        expect(store.records.map(\.id) == [1], "Qualified entry persisted")
        store.record(media(2, type: "video"), context: first); await store.waitForWrites()
        store.progress(id: 2, position: 20, duration: 100, flush: true, context: first); await store.waitForWrites()
        expect(store.resumePosition(for: 2) == 20, "Playback progress persists")
        store.progress(id: 99, position: 4, duration: 100, flush: true, context: first); await store.waitForWrites()
        expect(store.records.count == 2, "Unqualified video progress cannot create history")
        store.record(media(3), context: first)
        store.clear(context: first); await store.waitForWrites()
        expect(store.records.isEmpty && store.checkpoints.isEmpty, "Clear wins over pending writes")
        store.record(media(4), context: first); store.progress(id: 2, position: 30, duration: 100, flush: true, context: first)
        await store.waitForWrites()
        expect(store.records.isEmpty, "Late callbacks cannot recreate cleared history")
        do {
            let formatStore = BrowsingHistory(rootURL: root.appendingPathComponent("actual-format"))
            await formatStore.bind(ownerID: 28, identity: "controlled-format")
            let context = formatStore.context(ownerID: 28)!
            let metadataImage = media(280, type: "image")
            let decodedVideo = metadataImage.resolvingMediaType(isVideo: true)
            expect(!metadataImage.isVideo && decodedVideo.isVideo && decodedVideo.id == metadataImage.id
                   && decodedVideo.url == metadataImage.url && decodedVideo.creatorID == metadataImage.creatorID,
                   "Actual decoded type changes viewer/history interpretation without changing work identity or catalog metadata")
            formatStore.record(decodedVideo, context: context); await formatStore.waitForWrites()
            formatStore.progress(id: 280, position: 8, duration: 30, flush: true, context: context); await formatStore.waitForWrites()
            expect(formatStore.records.first(where: { $0.id == 280 })?.kind == .video && formatStore.resumePosition(for: 280) == 8,
                   "Image-labelled actual video keeps video history and resume position")
            formatStore.record(decodedVideo.resolvingMediaType(isVideo: false), context: context); await formatStore.waitForWrites()
            expect(formatStore.records.first(where: { $0.id == 280 })?.kind == .image && formatStore.resumePosition(for: 280) == nil,
                   "Video-labelled actual bitmap no longer exposes stale video resume")
        }
        let second = store.context(ownerID: 1)!
        store.setRecordingEnabled(false, context: second); await store.waitForWrites()
        let paused = store.context(ownerID: 1)!
        store.record(media(5), context: paused); await store.waitForWrites()
        expect(!store.recordingEnabled && store.records.isEmpty, "Recording opt-out enforced")
        store.setRecordingEnabled(true, context: paused); await store.waitForWrites()
        let enabled = store.context(ownerID: 1)!
        store.record(media(6), context: enabled); await store.waitForWrites()
        store.record(media(7), context: enabled)
        await store.bind(ownerID: 2, identity: "owner2-session1"); await store.waitForWrites()
        expect(store.records.isEmpty && !store.accepts(enabled), "Account switch invalidates callbacks and list")
        store.record(media(8), context: enabled); await store.waitForWrites()
        expect(store.records.isEmpty, "Old owner cannot populate new archive")
        await store.bind(ownerID: 1, identity: "owner1-session2")
        expect(store.records.contains(where: { $0.id == 6 }), "Original account archive retained")
        expect(!store.accepts(enabled), "Same owner new session rejects prior callbacks")
        let reboundVideo = media(70, type: "video")
        let preRebind = store.context(ownerID: 1)!
        store.record(reboundVideo, context: preRebind); await store.waitForWrites()
        store.progress(id: 70, position: 12, duration: 100, flush: true, context: preRebind); await store.waitForWrites()
        expect(store.resumePosition(for: 70) == 12, "Same-owner rebind fixture starts from a committed video progress")
        store.progress(id: 70, position: 40, duration: 100, flush: true, context: preRebind)
        for _ in 0..<8 { await Task.yield() }
        await store.bind(ownerID: 1, identity: "owner1-session2-rebound")
        let afterRebind = store.context(ownerID: 1)!
        expect(store.records.contains(where: { $0.id == 70 }), "Same-owner rebind rereads the previously committed record")
        store.progress(id: 70, position: 55, duration: 100, flush: true, context: afterRebind)
        store.record(media(71), context: afterRebind)
        await store.waitForWrites()
        await store.bind(ownerID: 1, identity: "owner1-session3")
        expect(Set(store.records.map(\.id)).isSuperset(of: [6,70,71]), "Repeated same-owner rebind retains earlier committed and newly committed records")
        expect(store.resumePosition(for: 70) == 55, "Newest committed progress survives the next same-owner archive reread")
        let current = store.context(ownerID: 1)!
        store.remove(ids: [6], context: current); await store.waitForWrites()
        expect(!store.records.contains(where: { $0.id == 6 }), "Single-record deletion works")
        let fresh = store.context(ownerID: 1)!
        store.record(media(20), context: fresh); await store.waitForWrites()
        await store.bind(ownerID: nil, identity: "anonymous")
        expect(store.records.isEmpty && store.context(ownerID: 1) == nil, "Anonymous identity separate")
        let candidates = [media(1), media(2, type: "video"), media(3, level: 4), media(4, tags: nil), media(5, tags: [.init(name: "hidden")]), media(6, author: nil), media(7, level: nil)]
        let ids = [2, 1, 2, 3, 4, 5, 6, 7]
        expect(HistoryMediaPolicy.ordered(candidates, ids: ids, blockedTags: []).map(\.id) == [2, 1, 4, 5, 6], "Current mask excludes disallowed and unknown ratings; ID order stable")
        expect(HistoryMediaPolicy.ordered(candidates, ids: ids, blockedTags: ["hidden"]).map(\.id) == [2, 1, 6], "Unknown and blocked tags hidden")
        expect(HistoryMediaPolicy.ordered(candidates, ids: ids, blockedTags: [], filter: FeedFilter(kind: .video)).map(\.id) == [2], "Media type constraint maintained")
        var knownVideo = media(80, type: "video")
        knownVideo.metadata = .init(duration: 120)
        var tooLongVideo = media(81, type: "video")
        tooLongVideo.metadata = .init(duration: 120.1)
        let durationCandidates = candidates + [knownVideo, tooLongVideo]
        let durationIDs = [80, 2, 1, 81]
        let durationFilter = FeedFilter(kind: .image, videoDurationRange: .init(minimumSeconds: 2, maximumSeconds: 120))
        expect(HistoryMediaPolicy.ordered(durationCandidates, ids: durationIDs, blockedTags: [], filter: durationFilter).map(\.id) == [80], "Active duration after hydration keeps only known inclusive video matches, independent of image selection")
        expect(HistoryMediaPolicy.ordered(durationCandidates, ids: durationIDs, blockedTags: [], filter: FeedFilter()).map(\.id) == durationIDs, "Disabled duration preserves unknown video and image during history hydration")
        expect(HistoryMediaPolicy.ordered(candidates, ids: ids, blockedTags: [], followingIDs: [7]).map(\.id) == [2, 1, 4, 5], "Following requires known current author membership")
        expect(HistoryMediaPolicy.ordered(candidates, ids: ids, blockedTags: [], filter: FeedFilter(onlyPG: true), allowedMask: 31).allSatisfy { $0.browsingLevel == 1 }, "PG constraint preserved independent of account mask")
        var cursor = PlaybackResumeCursor()
        expect(cursor.requested(initial: 30, recovery: nil) == 30, "First history open uses saved point")
        expect(PlaybackResumePolicy.waitsForDuration(position: 30, duration: 0), "Saved position remains pending before finite duration")
        expect(PlaybackResumePolicy.waitsForDuration(position: 30, duration: .infinity), "Indefinite duration cannot consume the saved position")
        expect(PlaybackResumePolicy.waitsForDuration(position: 30, duration: .nan), "Invalid duration cannot consume the saved position")
        expect(!PlaybackResumePolicy.waitsForDuration(position: nil, duration: 0), "A new video without a resume seed may start without duration")
        let pendingSeed = cursor.requested(initial: 30, recovery: nil)
        expect(!PlaybackResumePolicy.waitsForDuration(position: pendingSeed, duration: 100)
               && PlaybackResumePolicy.position(position: pendingSeed, duration: 100) == 30,
               "Saved 30 remains available after indefinite duration becomes finite 100")
        cursor.capture(position: 45, duration: 100, enabled: true)
        expect(cursor.requested(initial: 30, recovery: nil) == 45, "Returning to resumed video uses latest visit point")
        expect(cursor.requested(initial: 30, recovery: 46) == 46, "Address recovery preserves current playback point")
        cursor.capture(position: 99, duration: 100, enabled: true)
        expect(cursor.requested(initial: 30, recovery: nil) == nil, "Completed video does not reuse stale initial resume")
        var normalCursor = PlaybackResumeCursor()
        normalCursor.capture(position: 20, duration: 100, enabled: false)
        expect(normalCursor.requested(initial: nil, recovery: nil) == nil, "Ordinary feed videos retain normal restart behavior")
        var resumedCursor = PlaybackResumeCursor()
        resumedCursor.capture(position: 10, duration: 100, enabled: true)
        expect(resumedCursor.requested(initial: nil, recovery: nil) == 10, "Nil-seed history cursor retains the latest same-work position")
        resumedCursor.reset()
        expect(resumedCursor.requested(initial: nil, recovery: nil) == nil, "Leaving work resets its retained position")
        var intent = PlaybackUserIntent()
        intent.setPlaying(false)
        expect(!intent.shouldPlay(autoplay: true), "Explicit pause survives interruption despite autoplay preference")
        intent.reset()
        expect(intent.shouldPlay(autoplay: true), "Reset intent returns to the autoplay preference")
        intent.setPlaying(true)
        expect(intent.shouldPlay(autoplay: false), "Explicit manual play survives preference-off state until reset")
        intent.reset()
        expect(!intent.shouldPlay(autoplay: false), "Reset manual play returns to autoplay-off preference")

        let resumeRoot = root.appendingPathComponent("resume-disk", isDirectory: true)
        let writingFacade = BrowsingHistory(rootURL: resumeRoot)
        await writingFacade.bind(ownerID: 700, identity: "resume-before-background")
        let writingContext = writingFacade.context(ownerID: 700)!
        writingFacade.record(media(900, type: "video"), context: writingContext)
        await writingFacade.waitForWrites()
        writingFacade.progress(id: 900, position: 30, duration: 120, flush: true, context: writingContext)
        await writingFacade.waitForWrites()
        expect(writingFacade.records.first(where: { $0.id == 900 })?.positionSeconds == 30, "Existing video progress is committed before the background update")
        let canUpdateExisting = HistoryProgressPolicy.allows(qualifiedVisit: false, existingVideo: true,
                                                              contextIsCurrent: writingFacade.accepts(writingContext),
                                                              recordingEnabled: writingFacade.recordingEnabled)
        expect(canUpdateExisting, "A nonqualified continuation can update an existing video record")
        if canUpdateExisting {
            writingFacade.progress(id: 900, position: 60, duration: 120, flush: true, context: writingContext)
        }
        await writingFacade.waitForWrites()
        expect(writingFacade.records.first(where: { $0.id == 900 })?.positionSeconds == 60, "Flushed continuation progress reaches the facade archive")

        let fastFacade = BrowsingHistory(rootURL: resumeRoot)
        await fastFacade.bind(ownerID: 701, identity: "unknown-fast-work")
        let fastContext = fastFacade.context(ownerID: 701)!
        let canCreateUnknownFast = HistoryProgressPolicy.allows(qualifiedVisit: false, existingVideo: false,
                                                                contextIsCurrent: fastFacade.accepts(fastContext),
                                                                recordingEnabled: fastFacade.recordingEnabled)
        expect(!canCreateUnknownFast, "Unqualified fast work without an existing video record cannot be created by progress")
        if canCreateUnknownFast { fastFacade.progress(id: 901, position: 10, duration: 100, flush: true, context: fastContext) }
        await fastFacade.waitForWrites()
        expect(fastFacade.records.isEmpty, "Unknown fast video progress creates no history row")

        await writingFacade.bind(ownerID: 702, identity: "resume-account-switch")
        let staleAllowed = HistoryProgressPolicy.allows(qualifiedVisit: true, existingVideo: true,
                                                        contextIsCurrent: writingFacade.accepts(writingContext),
                                                        recordingEnabled: writingFacade.recordingEnabled)
        expect(!staleAllowed, "Account switch rejects a stale progress context")
        if staleAllowed { writingFacade.progress(id: 900, position: 80, duration: 120, flush: true, context: writingContext) }
        let rereadFacade = BrowsingHistory(rootURL: resumeRoot)
        await rereadFacade.bind(ownerID: 700, identity: "resume-after-background-reread")
        expect(rereadFacade.records.first(where: { $0.id == 900 })?.positionSeconds == 60, "New facade reads committed progress from the same temporary archive")
        let recordingContext = rereadFacade.context(ownerID: 700)!
        rereadFacade.setRecordingEnabled(false, context: recordingContext)
        await rereadFacade.waitForWrites()
        let disabledContext = rereadFacade.context(ownerID: 700)!
        let disabledAllowed = HistoryProgressPolicy.allows(qualifiedVisit: false, existingVideo: true,
                                                           contextIsCurrent: rereadFacade.accepts(disabledContext),
                                                           recordingEnabled: rereadFacade.recordingEnabled)
        expect(!disabledAllowed, "Recording opt-out rejects background progress policy")
        rereadFacade.progress(id: 900, position: 90, duration: 120, flush: true, context: disabledContext)
        await rereadFacade.waitForWrites()
        expect(rereadFacade.records.first(where: { $0.id == 900 })?.positionSeconds == 60, "Disabled facade progress does not overwrite stored position")

        let window = HistoryPlaybackRequest(ids: Array(1...120), focusedID: 83, context: fresh, resumePosition: nil)
        expect(window.ids.count <= 60 && window.ids.contains(83), "History entries after row60 retain requested selection")
        let endWindow = HistoryPlaybackRequest(ids: Array(1...120), focusedID: 120, context: fresh, resumePosition: nil)
        expect(endWindow.ids.contains(120), "Last history item remains in playback window")
        let checkpoint = TimelineCheckpoint.window(lane: .recommendation, filter: FeedFilter(), items: (1...80).map { media($0) }, focusedID: 71)
        expect(checkpoint?.ids.count ?? 100 <= 30 && checkpoint?.ids.contains(71) == true, "Timeline checkpoint bounds window without losing focused work")

        let baselineRoot = root.appendingPathComponent("resume-baseline-pruning", isDirectory: true)
        let seedBaseline = BrowsingHistory(rootURL: baselineRoot)
        await seedBaseline.bind(ownerID: 880, identity: "baseline-seeder")
        let baselineSeedContext = seedBaseline.context(ownerID: 880)!
        let baselineCheckpoint = TimelineCheckpoint(lane: .recommendation, filter: FeedFilter(), ids: [881,882,883], focusedID: 882, updatedAt: Date())
        seedBaseline.checkpoint(baselineCheckpoint, context: baselineSeedContext); await seedBaseline.waitForWrites()
        let baselineFacade = BrowsingHistory(rootURL: baselineRoot)
        await baselineFacade.bind(ownerID: 880, identity: "baseline-reader")
        let baselineContext = baselineFacade.context(ownerID: 880)!
        expect(baselineFacade.resumeOffer(for: .recommendation, context: baselineContext)?.ids == [881,882,883],
               "First bind captures the pre-existing checkpoint as this process offer baseline")
        baselineFacade.remove(ids: [881], context: baselineContext)
        let afterNonFocusRemoval = baselineFacade.context(ownerID: 880)!
        expect(baselineFacade.resumeOffer(for: .recommendation, context: afterNonFocusRemoval)?.ids == [882,883],
               "Removing a neighboring work synchronously prunes it from the offer baseline")
        baselineFacade.remove(ids: [882], context: afterNonFocusRemoval)
        let afterFocusRemoval = baselineFacade.context(ownerID: 880)!
        expect(baselineFacade.resumeOffer(for: .recommendation, context: afterFocusRemoval) == nil,
               "Removing the focused work synchronously consumes that resume offer before disk write completion")
        await baselineFacade.waitForWrites()

        let clearRoot = root.appendingPathComponent("resume-baseline-clear", isDirectory: true)
        let seedClear = BrowsingHistory(rootURL: clearRoot)
        await seedClear.bind(ownerID: 881, identity: "clear-seeder")
        seedClear.checkpoint(TimelineCheckpoint(lane: .following, filter: FeedFilter(), ids: [884], focusedID: 884, updatedAt: Date()),
                             context: seedClear.context(ownerID: 881)!)
        await seedClear.waitForWrites()
        let clearFacade = BrowsingHistory(rootURL: clearRoot)
        await clearFacade.bind(ownerID: 881, identity: "clear-reader")
        let beforeClearContext = clearFacade.context(ownerID: 881)!
        expect(clearFacade.resumeOffer(for: .following, context: beforeClearContext)?.focusedID == 884,
               "Clear fixture begins with a captured following offer")
        clearFacade.clear(context: beforeClearContext)
        let afterClearContext = clearFacade.context(ownerID: 881)!
        expect(clearFacade.resumeOffer(for: .following, context: afterClearContext) == nil,
               "Clear synchronously removes resume offers before the archive write completes")
        await clearFacade.waitForWrites()
        print("Browsing history store: \(checks) regression assertions passed")
    }
}
