import Foundation

@MainActor private final class FollowingMock: FollowingListSource {
    var followingIdentity = "acct"
    var followingActorID: Int? = 99
    var followingMemberIDs: Set<Int> = []
    var followingRevision = 0
    var refreshIDs: Set<Int> = []
    var refreshFailure = false
    var refreshGate: FollowingGate?
    var fetch: (Int, Int) async throws -> FollowingPage = { _, _ in .init(items: [], totalItems: 0, currentPage: 1, pageSize: 50, totalPages: 0) }
    var requested: [Int] = []
    func refreshFollowingIDs() async throws -> Set<Int> { if refreshFailure { throw URLError(.timedOut) }; if let refreshGate { await refreshGate.wait() }; return refreshIDs }
    func followingPage(page: Int, limit: Int) async throws -> FollowingPage { requested.append(page); return try await fetch(page, limit) }
}

@MainActor private final class FollowingGate {
    var continuation: CheckedContinuation<Void, Never>?
    var opened = false
    func wait() async { if !opened { await withCheckedContinuation { continuation = $0 } } }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

@main struct FollowingListChecks {
    @MainActor static func main() async throws {
        func creator(_ id: Int, _ name: String) -> Creator { .init(id: id, username: name, image: nil) }
        func page(_ items: [Creator], _ n: Int, _ size: Int, _ total: Int) -> FollowingPage {
            .init(items: items, totalItems: total, currentPage: n, pageSize: size, totalPages: max(1, (total + size - 1) / size))
        }
        let mock = FollowingMock(), store = FollowingListStore(pageSize: 2, batchPages: 1)
        let capped = FollowingListStore(pageSize: 500, batchPages: 50)
        precondition(capped.pageSize == 200 && capped.batchPages == 20, "Constructor preserves API page limit and caps batches at twenty pages")
        let rawIDs: Set<Int> = [1, 2, 3, 4, -1, 99]
        mock.followingMemberIDs = rawIDs; mock.refreshIDs = rawIDs
        let key = FollowingListKey(identity: "acct", memberIDs: rawIDs)
        mock.fetch = { p, _ in p == 1 ? page([creator(3,"Zed"), creator(1,"item10")], p, 2, 4) : page([creator(4,"item2"), creator(2,"Éclair")], p, 2, 4) }
        await store.reload(key: key, source: mock)
        precondition(store.creators.map(\.id) == [3,1] && !store.complete && store.canContinue && store.ordered(.name).isEmpty, "First page keeps server follow order and withholds incomplete global name order")
        precondition(store.ordered(.followed).isEmpty && store.nextPage == 2, "Neither partial normal nor reverse follow order is exposed as the complete list")
        await store.nextBatch(source: mock)
        precondition(store.complete && store.creators.map(\.id) == [3,1,4,2] && store.ordered(.followed).map(\.id) == [3,1,4,2] && store.ordered(.followed, reverse: true).map(\.id) == [2,4,1,3], "Reverse follow order reverses the actual server sequence")
        precondition(store.ordered(.name).map(\.id) == [2,3,4,1], "Complete name order uses the fixed POSIX collation and natural numeric runs")

        // One bounded batch can be resumed repeatedly without losing its cursor.
        let budget = FollowingListStore(pageSize: 1, batchPages: 1), four = FollowingListKey(identity: "acct", memberIDs: [10,11,12])
        mock.followingMemberIDs = [10,11,12]; mock.refreshIDs = [10,11,12]
        mock.fetch = { p, _ in page([creator(9+p,"N\(p)")], p, 1, 3) }
        await budget.reload(key: four, source: mock)
        precondition(budget.nextPage == 2 && !budget.complete && budget.canContinue, "A batch budget is explicit continuation, not false completion")
        await budget.nextBatch(source: mock); await budget.nextBatch(source: mock)
        precondition(budget.complete && budget.creators.count == 3 && mock.requested.suffix(3).elementsEqual([1,2,3]), "Continuation consumes each page once and reaches complete membership")

        // Invalid data fails closed and the exact uncommitted page can be retried.
        let bad = FollowingListStore(pageSize: 1, batchPages: 1)
        mock.followingMemberIDs = [20,21]; mock.refreshIDs = [20,21]
        let badKey = FollowingListKey(identity: "acct", memberIDs: [20,21])
        mock.fetch = { p, _ in p == 1 ? page([creator(20,"A")],1,1,2) : page([creator(20,"A")],2,1,2) }
        await bad.reload(key: badKey, source: mock); await bad.nextBatch(source: mock)
        precondition(bad.error != nil && !bad.complete && bad.nextPage == 2, "Repeated creators are rejected without advancing the failed page")
        mock.fetch = { p, _ in p == 1 ? page([creator(20,"A")],1,1,2) : page([creator(21,"B")],2,1,2) }
        await bad.nextBatch(source: mock)
        precondition(bad.complete && bad.error == nil && bad.creators.map(\.id) == [20,21], "Retry resumes the same page and completes")

        let invalids: [([Creator], Int, Int, Int, FollowingListError)] = [
            ([creator(20,"A")], 2, 2, 2, .invalidPage),
            ([creator(999,"Outside")], 1, 1, 1, .unexpectedCreator),
            ([creator(20,"A"), creator(20,"A")], 1, 2, 2, .duplicateCreator)
        ]
        for (items, size, total, _, _) in invalids {
            let s = FollowingListStore(pageSize: size, batchPages: 1)
            let ids: Set<Int> = [20]
            mock.followingMemberIDs = ids; mock.refreshIDs = ids
            mock.fetch = { _, _ in page(items, 1, size, total) }
            await s.reload(key: .init(identity: "acct", memberIDs: ids), source: mock)
            precondition(s.error != nil && !s.complete, "Malformed count, unrelated creator or duplicate page must not complete")
        }

        // A count change between valid pages is an explicit retryable error.
        let changing = FollowingListStore(pageSize: 1, batchPages: 1)
        mock.followingMemberIDs = [30,31]; mock.refreshIDs = [30,31]
        mock.fetch = { p, _ in p == 1 ? page([creator(30,"A")],1,1,2) : page([creator(31,"B")],2,1,3) }
        await changing.reload(key: .init(identity: "acct", memberIDs: [30,31]), source: mock); await changing.nextBatch(source: mock)
        precondition(changing.error != nil && !changing.complete && changing.nextPage == 2, "Changing total count remains an error at the current page")

        let finalMismatch = FollowingListStore(pageSize: 2, batchPages: 1)
        mock.followingMemberIDs = [32,33]; mock.refreshIDs = [32,33]
        mock.fetch = { _, _ in page([creator(32,"A")],1,2,1) }
        await finalMismatch.reload(key: .init(identity: "acct", memberIDs: [32,33]), source: mock)
        precondition(finalMismatch.error != nil && finalMismatch.creators.isEmpty && finalMismatch.nextPage == 1 && finalMismatch.totalItems == 0, "Final set mismatch commits neither rows, count nor cursor")
        mock.fetch = { _, _ in page([creator(32,"A"), creator(33,"B")],1,2,2) }
        await finalMismatch.nextBatch(source: mock)
        precondition(finalMismatch.complete && finalMismatch.creators.count == 2, "Final membership failure retries the same page cleanly")

        let invalidSnapshot = FollowingListStore()
        mock.followingMemberIDs = [0]; mock.refreshIDs = [0]
        await invalidSnapshot.reload(key: .init(identity: "acct", memberIDs: [0]), source: mock)
        precondition(invalidSnapshot.error?.contains("无效作者 ID") == true && !invalidSnapshot.complete, "Only known system and current-actor IDs may be excluded from snapshots")

        let zeroCountPage = FollowingListStore()
        mock.followingMemberIDs = [80]; mock.refreshIDs = [80]
        mock.fetch = { _, _ in page([],1,50,0) }
        await zeroCountPage.reload(key: .init(identity: "acct", memberIDs: [80]), source: mock)
        precondition(zeroCountPage.error == FollowingListError.incomplete.errorDescription && zeroCountPage.nextPage == 1, "API count zero with totalPages one is parsed as a valid empty page but cannot contradict confirmed membership")

        // Relationship and account changes are detected before and after requests.
        let changed = FollowingListStore(pageSize: 1, batchPages: 1)
        mock.followingMemberIDs = [40]; mock.refreshIDs = [41]
        await changed.reload(key: .init(identity: "acct", memberIDs: [40]), source: mock)
        precondition(changed.error != nil && changed.creators.isEmpty, "Refreshed relationship set must match the key")
        mock.followingMemberIDs = [40]; mock.refreshIDs = [40]; mock.followingIdentity = "other"
        await changed.reload(key: .init(identity: "acct", memberIDs: [40]), source: mock)
        precondition(changed.error != nil && changed.creators.isEmpty, "Account switch cannot populate the previous account context")
        mock.followingIdentity = "acct"

        // Old in-flight work cannot overwrite a newer key; cancellation also preserves state.
        let late = FollowingListStore(pageSize: 1, batchPages: 1), started = FollowingGate(), release = FollowingGate()
        mock.followingMemberIDs = [50]; mock.refreshIDs = [50]
        mock.fetch = { _, _ in started.open(); await release.wait(); return page([creator(50,"Old")],1,1,1) }
        let oldTask = Task { await late.reload(key: .init(identity: "acct", memberIDs: [50]), source: mock) }
        await started.wait()
        mock.followingMemberIDs = [50]; mock.refreshIDs = [50]
        mock.fetch = { _, _ in page([creator(50,"New")],1,1,1) }
        await late.reload(key: .init(identity: "acct", memberIDs: [50]), source: mock)
        release.open(); await oldTask.value
        precondition(late.creators.first?.username == "New" && late.complete, "A same-key reopen supersedes a late prior request")

        let cancelled = FollowingListStore(pageSize: 1, batchPages: 1), cancelStarted = FollowingGate(), cancelRelease = FollowingGate()
        mock.followingMemberIDs = [70]; mock.refreshIDs = [70]
        mock.fetch = { _, _ in cancelStarted.open(); await cancelRelease.wait(); return page([creator(70,"Cancelled")],1,1,1) }
        let cancelledTask = Task { await cancelled.reload(key: .init(identity: "acct", memberIDs: [70]), source: mock) }
        await cancelStarted.wait(); cancelledTask.cancel(); cancelRelease.open(); await cancelledTask.value
        precondition(cancelled.creators.isEmpty && !cancelled.complete && !cancelled.loading && cancelled.error != nil, "Cancelled in-flight response cannot commit rows or claim completion and remains retryable")
        mock.fetch = { _, _ in page([creator(70,"Retry")],1,1,1) }
        await cancelled.reload(key: .init(identity: "acct", memberIDs: [70]), source: mock)
        precondition(cancelled.complete && cancelled.creators.first?.username == "Retry", "A cancelled load can retry the same key")

        let emptyCancelled = FollowingListStore(), refreshGate = FollowingGate()
        mock.followingMemberIDs = []; mock.refreshIDs = []; mock.refreshGate = refreshGate
        let emptyCancelledTask = Task { await emptyCancelled.reload(key: .init(identity: "acct", memberIDs: []), source: mock) }
        await Task.yield(); emptyCancelledTask.cancel(); refreshGate.open(); await emptyCancelledTask.value
        mock.refreshGate = nil
        precondition(!emptyCancelled.complete && emptyCancelled.error != nil, "Cancellation after ID refresh cannot falsely complete an empty list")

        // A confirmed empty relationship set is the only empty-list success path.
        let empty = FollowingListStore()
        mock.followingMemberIDs = []; mock.refreshIDs = []
        let emptyRequestCount = mock.requested.count
        await empty.reload(key: .init(identity: "acct", memberIDs: []), source: mock)
        precondition(empty.complete && empty.creators.isEmpty && mock.requested.count == emptyRequestCount, "Confirmed empty IDs complete without inventing a creator or API page")

        // An unfollow/refollow cycle can end at the same set with a new time order.
        let reordered = FollowingListStore(pageSize: 2)
        let sameIDs: Set<Int> = [90,91]
        mock.followingMemberIDs = sameIDs; mock.refreshIDs = sameIDs
        mock.fetch = { _, _ in page([creator(91,"Old first"),creator(90,"Old last")],1,2,2) }
        let firstRevision = FollowingListKey(identity: "acct", memberIDs: sameIDs, revision: 0)
        await reordered.reload(key: firstRevision, source: mock)
        await reordered.reload(key: firstRevision, source: mock)
        precondition(reordered.complete && reordered.requestKey == firstRevision && mock.followingRevision == 0, "Ordinary reads of the same membership keep the revision stable and complete without a reload loop")
        mock.followingRevision = 2
        let refollowed = FollowingListKey(identity: "acct", memberIDs: sameIDs, revision: 2)
        precondition(firstRevision != refollowed, "S to S-minus-author to S keeps a distinct cache key after confirmed relationship changes")
        mock.fetch = { _, _ in page([creator(90,"Refollowed"),creator(91,"Other")],1,2,2) }
        await reordered.reload(key: refollowed, source: mock)
        precondition(reordered.complete && reordered.ordered(.followed).map(\.id) == [90,91], "The same final membership with a new revision reads the new server follow order")
        let revisionStarted = FollowingGate(), revisionRelease = FollowingGate(), staleRevision = FollowingListStore(pageSize: 2)
        mock.fetch = { _, _ in revisionStarted.open(); await revisionRelease.wait(); return page([creator(91,"Stale"),creator(90,"Stale")],1,2,2) }
        let revisionTask = Task { await staleRevision.reload(key: refollowed, source: mock) }
        await revisionStarted.wait(); mock.followingRevision = 4; revisionRelease.open(); await revisionTask.value
        precondition(staleRevision.creators.isEmpty && !staleRevision.complete && staleRevision.error == FollowingListError.membershipChanged.errorDescription, "A late same-set page cannot commit after a confirmed unfollow/refollow cycle")

        print("FollowingListChecks: 26 regression checks passed")
    }
}
