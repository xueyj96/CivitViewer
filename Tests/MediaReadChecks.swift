import Foundation

/// This fake implements only the history media-reading capability. The test runs
/// the production MediaRead.swift extension without requests, credentials or WKWebView.
@MainActor final class FakeHistorySource: HistoryMediaReading {
    var feedIdentity = "account-A"
    var followingMemberIDs = Set<Int>()
    var mediaByID: [Int: MediaItem] = [:]
    var creatorsByHandle: [String: Creator] = [:]
    var failingCreatorHandles = Set<String>()
    var mediaBatches: [[Int]] = []
    var creatorLookups: [String] = []
    var afterMedia: (@MainActor () async -> Void)?
    var afterCreator: (@MainActor () async -> Void)?
    var mediaDelay: Duration?

    func mediaItems(ids: [Int], includeTags: Bool) async throws -> [MediaItem] {
        mediaBatches.append(ids)
        if let mediaDelay { try await Task.sleep(for: mediaDelay) }
        if let afterMedia { await afterMedia() }
        return ids.compactMap { mediaByID[$0] }
    }

    func creator(username: String) async throws -> Creator {
        creatorLookups.append(username)
        if let afterCreator { await afterCreator() }
        let key = AuthorHandlePolicy.normalize(username)
        if failingCreatorHandles.contains(key) { throw ClientError.invalidResponse }
        guard let creator = creatorsByHandle[key] else { throw ClientError.missingCreator }
        return creator
    }
}

@main struct MediaReadChecks {
    @MainActor static func main() async {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            precondition(condition(), message)
        }
        func media(_ id: Int, username: String?, creatorID: Int? = nil) -> MediaItem {
            MediaItem(id: id, url: "https://example.invalid/\(id)", width: 100, height: 100, type: "image",
                      username: username, browsingLevel: 1, thumbnail: nil, creatorID: creatorID)
        }

        let session = FakeHistorySource()
        session.followingMemberIDs = [7, 77]
        session.mediaByID = [
            1: media(1, username: "Alice"), 2: media(2, username: " alice "),
            3: media(3, username: "Alice", creatorID: 77), 4: media(4, username: nil)
        ]
        session.creatorsByHandle["alice"] = Creator(id: 7, username: "Alice", image: nil)
        let followingItems = try! await session.resumeMediaItems(ids: [1, 2, 3, 4], followingIDs: [7, 77], isCurrent: { true })
        check(followingItems.map(\.creatorID) == [7, 7, 77, nil], "Exact canonical hydration fills nil IDs, preserves fresh known IDs and leaves anonymous media unknown")
        check(session.creatorLookups == ["Alice"], "Equivalent normalized author names resolve only once")
        check(session.mediaBatches == [[1, 2, 3, 4]], "Small history windows use one media request")

        let batchSession = FakeHistorySource()
        batchSession.mediaByID = Dictionary(uniqueKeysWithValues: (1...35).map { ($0, media($0, username: nil)) })
        _ = try! await batchSession.resumeMediaItems(ids: Array(1...35), followingIDs: nil, isCurrent: { true })
        check(batchSession.mediaBatches.map(\.count) == [30, 5], "Media ID reads stay in batches of at most 30")
        do {
            _ = try await batchSession.resumeMediaItems(ids: Array(1...61), followingIDs: nil, isCurrent: { true })
            check(false, "More than 60 IDs must be rejected")
        } catch is ClientError {
            check(batchSession.mediaBatches.count == 2, "The 60-ID total cap is enforced before additional reads")
        } catch { check(false, "ID cap reports a client validation error") }

        let budgetSession = FakeHistorySource()
        budgetSession.followingMemberIDs = Set(1...31)
        budgetSession.mediaByID = Dictionary(uniqueKeysWithValues: (1...31).map { ($0, media($0, username: "author-\($0)")) })
        for id in 1...31 { budgetSession.creatorsByHandle["author-\(id)"] = Creator(id: id, username: "author-\(id)", image: nil) }
        let budgetResult = try! await budgetSession.resumeMediaItems(ids: Array(1...31), followingIDs: Set(1...31), isCurrent: { true })
        check(budgetSession.creatorLookups.count == 30 && budgetResult.prefix(30).allSatisfy { $0.creatorID != nil } && budgetResult.last?.creatorID == nil,
              "Following author resolution has a total 30-name budget")

        let missingSession = FakeHistorySource()
        missingSession.followingMemberIDs = [7]
        missingSession.mediaByID[1] = media(1, username: "missing")
        let missingResult = try! await missingSession.resumeMediaItems(ids: [1], followingIDs: [7], isCurrent: { true })
        check(missingResult.first?.creatorID == nil, "An author lookup with no exact result is tolerated without inventing membership")
        let ambiguous = AuthorHandlePolicy.attachingFollowingCreatorIDs([media(1, username: "alice")],
            resolved: [Creator(id: 7, username: "Alice", image: nil), Creator(id: 8, username: "ALICE", image: nil)], followingIDs: [7, 8])
        check(ambiguous.first?.creatorID == nil, "Ambiguous normalized handles cannot attach an author ID")
        let outsideSet = AuthorHandlePolicy.attachingFollowingCreatorIDs([media(1, username: "alice")],
            resolved: [Creator(id: 9, username: "Alice", image: nil)], followingIDs: [7])
        check(outsideSet.first?.creatorID == nil, "A resolved but non-followed creator cannot attach")

        let identitySession = FakeHistorySource()
        identitySession.mediaByID[1] = media(1, username: nil)
        identitySession.afterMedia = { identitySession.feedIdentity = "account-B" }
        do {
            _ = try await identitySession.resumeMediaItems(ids: [1], followingIDs: nil, isCurrent: { true })
            check(false, "Account change during media hydration must invalidate the result")
        } catch is CancellationError { check(true, "Account change cancels the staged media result") }
        catch { check(false, "Account change surfaces as cancellation") }

        let followingSession = FakeHistorySource()
        followingSession.followingMemberIDs = [7]
        followingSession.mediaByID[1] = media(1, username: "alice")
        followingSession.creatorsByHandle["alice"] = Creator(id: 7, username: "Alice", image: nil)
        followingSession.afterCreator = { followingSession.followingMemberIDs = [8] }
        do {
            _ = try await followingSession.resumeMediaItems(ids: [1], followingIDs: [7], isCurrent: { true })
            check(false, "Following change during author resolution must invalidate the result")
        } catch is CancellationError { check(true, "Changed follow snapshot cancels staged enrichment") }
        catch { check(false, "Follow change surfaces as cancellation") }

        let currentSession = FakeHistorySource()
        do {
            _ = try await currentSession.resumeMediaItems(ids: [1], followingIDs: nil, isCurrent: { false })
            check(false, "A stale caller ticket must stop before reading")
        } catch is CancellationError { check(currentSession.mediaBatches.isEmpty, "Stale caller context is rejected before the first media read") }
        catch { check(false, "Stale caller context surfaces as cancellation") }

        let cancelledSession = FakeHistorySource()
        cancelledSession.mediaByID[1] = media(1, username: nil)
        cancelledSession.mediaDelay = .seconds(5)
        let pending = Task { @MainActor in
            try await cancelledSession.resumeMediaItems(ids: [1], followingIDs: nil, isCurrent: { true })
        }
        try? await Task.sleep(for: .milliseconds(20))
        pending.cancel()
        do { _ = try await pending.value; check(false, "Cancellation during media read must not return partial results") }
        catch is CancellationError { check(true, "Cancellation while awaiting a batch propagates without committing partial history") }
        catch { check(false, "Cancellation surfaces as CancellationError") }

        let failureSession = FakeHistorySource()
        failureSession.followingMemberIDs = [7]
        failureSession.mediaByID[1] = media(1, username: "alice")
        failureSession.failingCreatorHandles = ["alice"]
        do {
            _ = try await failureSession.resumeMediaItems(ids: [1], followingIDs: [7], isCurrent: { true })
            check(false, "Non-missing creator lookup errors must propagate")
        } catch is ClientError { check(true, "Only missingCreator is tolerated; other lookup errors propagate") }
        catch { check(false, "Unexpected error from fake history source") }

        print("MediaReadChecks: \(checks) local assertions passed; data methods are fake, production extension exercised")
    }
}
