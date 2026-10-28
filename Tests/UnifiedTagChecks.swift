import Foundation

@MainActor private final class UnifiedTagSource: TagDirectorySource {
    var feedIdentity = "feed-A"
    var lookupIdentity = "lookup-A"
    var tagLookupIdentity: String { lookupIdentity }
    var localCalls: [(TagDirectoryMode,String,Int?)] = []
    var onlineCalls: [(TagDirectoryMode,String,Int)] = []
    var remembered: [(ids:[Int],common:Bool,identity:String)] = []
    var local: (TagDirectoryMode,String,TagDirectoryCursor?) async throws -> TagDirectoryPage = { _,_,cursor in .init(items: [], next: nil) }
    var online: (TagDirectoryMode,String,Int) async throws -> [SearchTag]? = { _,_,_ in nil }
    var remember: ([SearchTag],Bool,String) async throws -> Void = { _,_,_ in }

    func commonTags() async throws -> [SearchTag] { [] }
    func catalogTags(keyword: String, page: Int) async throws -> [SearchTag] { [] }
    func exactTag(name: String) async throws -> SearchTag? { nil }
    func directoryPage(mode: TagDirectoryMode, keyword: String, cursor: TagDirectoryCursor?) async throws -> TagDirectoryPage {
        localCalls.append((mode,keyword,cursor?.page))
        return try await local(mode,keyword,cursor)
    }
    func onlineTagPage(mode: TagDirectoryMode, keyword: String, page: Int) async throws -> [SearchTag]? {
        onlineCalls.append((mode,keyword,page))
        return try await online(mode,keyword,page)
    }
    func rememberTags(_ tags: [SearchTag], common: Bool, identity: String) async throws {
        try await remember(tags,common,identity)
        remembered.append((tags.map(\.id),common,identity))
    }
}

@MainActor private final class UnifiedTagGate {
    var opened = false
    var waiters: [CheckedContinuation<Void,Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { waiters.append($0) } } }
    func open() { opened = true; let values = waiters; waiters = []; values.forEach { $0.resume() } }
}

@main struct UnifiedTagChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1; precondition(condition(), message)
        }
        func tag(_ id: Int, _ name: String) -> SearchTag { SearchTag(id: id, name: name, nsfwLevel: id % 4) }
        func key(_ mode: TagDirectoryMode = .catalog, _ keyword: String = "", _ source: UnifiedTagSource) -> TagDirectoryStore.Key {
            .init(mode: mode, keyword: keyword, identity: source.tagLookupIdentity)
        }
        let source = UnifiedTagSource(); var clock = [Date(timeIntervalSince1970: 1_800_000_000)]
        let store = TagDirectoryStore(debounceNanoseconds: 0, cachePageLimit: 2, now: { clock[0] })

        // Local rows are published before a blocked remote request returns.
        let remoteGate = UnifiedTagGate(), remoteStarted = UnifiedTagGate()
        source.local = { _,_,_ in .init(items: [tag(1,"cat-old"),tag(4,"catalog")], next: nil) }
        source.online = { mode,keyword,page in
            remoteStarted.open(); await remoteGate.wait()
            return [tag(1,"Cat"),tag(3,"cat")]
        }
        let localFirst = Task { await store.reload(key: key(.catalog,"cat",source), source: source) }
        await remoteStarted.wait()
        check(store.tags.map(\.id) == [1,4] && store.onlineLoading && store.loading, "Local results display while online fetch is still pending")
        remoteGate.open(); await localFirst.value
        check(store.tags.map(\.id) == [1,3,4] && store.tags.first?.name == "Cat", "Remote same-ID metadata replaces local data and keeps deterministic exact-name ordering")
        check(store.tags.map(\.id).count == Set(store.tags.map(\.id)).count && store.reachedEnd, "Canonical IDs merge once and both short lanes reach end")
        check(source.onlineCalls.last?.1 == "cat" && source.remembered.last?.identity == source.tagLookupIdentity, "Remote requests and remember calls use normalized query and captured lookup identity")

        // Search order is exact normalized name, normalized lexical name, then ID.
        // A local failure does not suppress a valid online result; cache write failure is separate.
        let localFailure = UnifiedTagSource(), localFailureStore = TagDirectoryStore(debounceNanoseconds: 0)
        localFailure.local = { _,_,_ in throw URLError(.timedOut) }
        localFailure.online = { _,_,_ in [tag(20,"garden")] }
        localFailure.remember = { _,_,_ in throw NSError(domain: "fixture-cache", code: 1) }
        await localFailureStore.reload(key: key(.catalog,"garden",localFailure), source: localFailure)
        check(localFailureStore.error != nil && localFailureStore.onlineError == nil && localFailureStore.tags.map(\.id) == [20], "Local failure remains visible while remote rows still populate")
        check(localFailureStore.cacheError != nil && localFailureStore.tags.map(\.id) == [20], "Remember failure is a cache error and keeps remote results")

        // Online failure keeps local rows and leaves the failed page available for retry.
        let retrySource = UnifiedTagSource(), retryStore = TagDirectoryStore(debounceNanoseconds: 0)
        var shouldFail = true
        retrySource.local = { _,_,_ in .init(items: [tag(30,"flower")], next: nil) }
        retrySource.online = { _,_,page in
            if shouldFail { throw URLError(.timedOut) }
            return [tag(31,"flower")]
        }
        await retryStore.reload(key: key(.catalog,"flower",retrySource), source: retrySource)
        check(retryStore.tags.map(\.id) == [30] && retryStore.onlineError != nil && !retryStore.reachedEnd, "Remote failure leaves local content and a retryable online lane")
        shouldFail = false; await retryStore.retryOnline(source: retrySource)
        check(retrySource.onlineCalls.map(\.2) == [1,1] && retryStore.tags.map(\.id) == [30,31] && retryStore.onlineError == nil, "Online retry repeats the failed page without clearing local rows")
        let successfulRetryCalls = retrySource.onlineCalls.count
        retrySource.local = { _,_,_ in .init(items:[],next:nil) }
        await retryStore.reload(key:key(.catalog,"flower",retrySource),source:retrySource)
        check(retryStore.tags.map(\.id) == [30,31] && retrySource.onlineCalls.count == successfulRetryCalls, "Successful online retry saves a coherent query snapshot for stable repeat reads")

        // Genuine empty responses are cached briefly, while failures are never cached.
        let ttlSource = UnifiedTagSource(), ttlStore = TagDirectoryStore(debounceNanoseconds: 0, now: { clock[0] })
        ttlSource.online = { _,_,_ in [] }
        await ttlStore.reload(key: key(.catalog,"empty",ttlSource), source: ttlSource)
        check(ttlStore.tags.isEmpty && ttlStore.reachedEnd && ttlStore.onlineError == nil, "Zero results from both lanes are a successful end state")
        let emptyCalls = ttlSource.onlineCalls.count
        clock[0].addTimeInterval(29)
        await ttlStore.reload(key: key(.catalog," EMPTY ",ttlSource), source: ttlSource)
        check(ttlSource.onlineCalls.count == emptyCalls && ttlStore.reachedEnd, "Normalized empty query reuses empty cache within its 30-second TTL")
        clock[0].addTimeInterval(2)
        await ttlStore.reload(key: key(.catalog,"empty",ttlSource), source: ttlSource)
        check(ttlSource.onlineCalls.count == emptyCalls + 1, "Empty page cache expires after 30 seconds")

        let dataSource = UnifiedTagSource(), dataStore = TagDirectoryStore(debounceNanoseconds: 0, now: { clock[0] })
        dataSource.online = { _,keyword,_ in [tag(40,TagPolicy.normalize(keyword))] }
        await dataStore.reload(key: key(.catalog,"Plant",dataSource), source: dataSource)
        let dataCalls = dataSource.onlineCalls.count
        await dataStore.reload(key: key(.catalog," plant ",dataSource), source: dataSource)
        check(dataSource.onlineCalls.count == dataCalls && dataStore.tags.map(\.id) == [40], "Repeated normalized search reuses a successful nonempty page")
        clock[0].addTimeInterval(299)
        await dataStore.reload(key: key(.catalog,"plant",dataSource), source: dataSource)
        check(dataSource.onlineCalls.count == dataCalls, "Successful page remains cached within 300 seconds")
        clock[0].addTimeInterval(2)
        await dataStore.reload(key: key(.catalog,"plant",dataSource), source: dataSource)
        check(dataSource.onlineCalls.count == dataCalls + 1, "Nonempty page expires after 300 seconds")
        dataSource.lookupIdentity = "lookup-B"
        await dataStore.reload(key: key(.catalog,"plant",dataSource), source: dataSource)
        check(dataSource.onlineCalls.count == dataCalls + 2, "Changing lookup identity clears the page cache")
        await dataStore.reload(key: key(.catalog,"plant",dataSource), source: dataSource, forceRemote: true)
        check(dataSource.onlineCalls.count == dataCalls + 3, "Force-remote reload bypasses a fresh cached page")

        // Successful whole-query snapshots make repeats independent of local DB mutations from rememberTags.
        let mutableSource = UnifiedTagSource(), mutableStore = TagDirectoryStore(debounceNanoseconds: 0, now: { clock[0] })
        var mutableRows: [SearchTag] = (1...20).map { tag($0, "f-local-\($0)") }
        mutableSource.local = { _,keyword,_ in
            let prefix = keyword == "city" ? "city-local" : "f-local"
            return .init(items: mutableRows.filter { $0.name.hasPrefix(prefix) }.sorted { $0.name < $1.name }.prefix(20).map{$0}, next:nil)
        }
        mutableSource.online = { _,keyword,page in
            if keyword == "city" { return [tag(500,"city remote")] }
            if page == 1 { return (101...120).map { tag($0,"f-remote-\($0)") } }
            return [tag(121,"f-remote-121")]
        }
        mutableSource.remember = { tags,_,_ in
            for item in tags {
                if let index = mutableRows.firstIndex(where:{$0.id == item.id}) { mutableRows[index] = item }
                else { mutableRows.append(item) }
            }
        }
        await mutableStore.reload(key:key(.catalog,"f",mutableSource),source:mutableSource)
        let firstFIDs = mutableStore.tags.map(\.id), firstOnlineCalls = mutableSource.onlineCalls.count
        await mutableStore.reload(key:key(.catalog,"city",mutableSource),source:mutableSource)
        await mutableStore.reload(key:key(.catalog,"f",mutableSource),source:mutableSource)
        check(mutableStore.tags.map(\.id) == firstFIDs && mutableSource.onlineCalls.count == firstOnlineCalls + 1, "Switching query back restores the original full query snapshot without local-prefix drift or extra remote calls")
        await mutableStore.next(source:mutableSource)
        let continuedFIDs = mutableStore.tags.map(\.id), afterNextCalls = mutableSource.onlineCalls.count
        await mutableStore.reload(key:key(.catalog,"f",mutableSource),source:mutableSource)
        check(mutableStore.tags.map(\.id) == continuedFIDs && mutableSource.onlineCalls.count == afterNextCalls, "Snapshot preserves continuation cursors and next-page results across reload")
        await mutableStore.reload(key:key(.catalog,"f",mutableSource),source:mutableSource,forceRemote:true)
        check(mutableSource.onlineCalls.count > afterNextCalls, "Force remote bypasses whole-query snapshots and revalidates")
        let callsAfterForce = mutableSource.onlineCalls.count
        clock[0].addTimeInterval(301)
        await mutableStore.reload(key:key(.catalog,"f",mutableSource),source:mutableSource)
        check(mutableSource.onlineCalls.count > callsAfterForce, "Expired query snapshot is rebuilt from current local data and revalidated online")

        // LRU evicts the least recently used page at the configured test capacity.
        let lruSource = UnifiedTagSource(), lruStore = TagDirectoryStore(debounceNanoseconds: 0, cachePageLimit: 2, now: { clock[0] })
        lruSource.local = { _,_,_ in throw URLError(.timedOut) } // prevent whole-query snapshots; exercise the page cache directly
        lruSource.online = { _,keyword,_ in [tag(50 + Int(keyword.hashValue.magnitude % 10_000), TagPolicy.normalize(keyword))] }
        await lruStore.reload(key: key(.catalog,"one",lruSource), source: lruSource)
        await lruStore.reload(key: key(.catalog,"two",lruSource), source: lruSource)
        await lruStore.reload(key: key(.catalog,"one",lruSource), source: lruSource) // refresh one
        await lruStore.reload(key: key(.catalog,"three",lruSource), source: lruSource)
        let afterThree = lruSource.onlineCalls.count
        await lruStore.reload(key: key(.catalog,"one",lruSource), source: lruSource)
        check(lruSource.onlineCalls.count == afterThree, "Recently used cache page survives LRU eviction")
        await lruStore.reload(key: key(.catalog,"two",lruSource), source: lruSource)
        check(lruSource.onlineCalls.count == afterThree + 1, "Least recently used cache page is evicted")

        // Empty common mode preserves latest online rank, with canonical metadata replacement.
        let commonSource = UnifiedTagSource(), commonStore = TagDirectoryStore(debounceNanoseconds: 0)
        commonSource.local = { _,_,_ in .init(items: [tag(9,"local-nine"),tag(5,"local-five")], next: nil) }
        commonSource.online = { _,_,_ in [tag(5,"remote-five"),tag(4,"remote-four"),tag(9,"remote-nine")] }
        await commonStore.reload(key: key(.common,"",commonSource), source: commonSource)
        check(commonStore.tags.map(\.id) == [5,4,9] && commonStore.tags.first?.name == "remote-five", "Common mode preserves latest remote rank and replaces old same-ID metadata")
        check(commonSource.remembered.last?.common == true, "Only the authoritative first common response is remembered as common")

        let commonSnapshot = UnifiedTagSource(), commonSnapshotStore = TagDirectoryStore(debounceNanoseconds: 0)
        commonSnapshot.local = { _,_,_ in .init(items:[tag(90,"stale-local"),tag(91,"removed-local")],next:nil) }
        let ranked22 = (1...22).map { tag(1_000 + $0, "common-\($0)") }
        commonSnapshot.online = { _,_,_ in ranked22 }
        await commonSnapshotStore.reload(key:key(.common,"",commonSnapshot),source:commonSnapshot)
        check(commonSnapshotStore.tags.map(\.id) == ranked22.map(\.id) && commonSnapshotStore.reachedEnd, "A 22-tag authoritative common snapshot is accepted and replaces removed local-only common rows")
        check(commonSnapshot.onlineCalls.map(\.2) == [1] && commonSnapshot.remembered.last?.common == true, "Common snapshot is a single response, never paged")

        let emptyCommon = UnifiedTagSource(), emptyCommonStore = TagDirectoryStore(debounceNanoseconds: 0)
        emptyCommon.local = { _,_,_ in .init(items:[tag(92,"stale-common")],next:nil) }
        emptyCommon.online = { _,_,_ in [] }
        await emptyCommonStore.reload(key:key(.common,"",emptyCommon),source:emptyCommon)
        check(emptyCommonStore.tags.isEmpty && emptyCommonStore.reachedEnd && emptyCommon.onlineCalls.map(\.2) == [1], "A successful empty common snapshot authoritatively clears stale common rows")

        let catalogSource = UnifiedTagSource(), catalogStore = TagDirectoryStore(debounceNanoseconds: 0)
        catalogSource.local = { _,_,_ in .init(items: [tag(8,"zebra"),tag(5,"apple"),tag(3,"Apple")], next: nil) }
        await catalogStore.reload(key: key(.catalog,"",catalogSource), source: catalogSource)
        check(catalogStore.tags.map(\.id) == [3,5,8], "Empty catalog mode sorts by normalized name then canonical ID")

        let exactSource = UnifiedTagSource(), exactStore = TagDirectoryStore(debounceNanoseconds: 0)
        exactSource.local = { _,_,_ in .init(items: [tag(1,"catapult"),tag(9,"CAT"),tag(3,"catalog"),tag(2,"cat")], next: nil) }
        await exactStore.reload(key: key(.catalog," Cat ",exactSource), source: exactSource)
        check(exactStore.tags.map(\.id) == [2,9,3,1], "Nonempty search ranks exact normalized names, then lexical names, then IDs")
        check(exactStore.tags.count == Set(exactStore.tags.map(\.id)).count, "Different IDs with similar names remain separate rows")

        // Both lanes stop repeating full all-seen pages without advancing the failed cursor.
        let repeatLocal = UnifiedTagSource(), repeatLocalStore = TagDirectoryStore(debounceNanoseconds: 0)
        let fullLocal = (1...20).map { tag($0,"l\($0)") }
        var localRetry = false
        repeatLocal.local = { _,_,cursor in
            if cursor == nil { return .init(items:fullLocal,next:.init(page:2)) }
            return localRetry ? .init(items:[tag(21,"l21")],next:nil) : .init(items:fullLocal,next:.init(page:3))
        }
        await repeatLocalStore.reload(key: key(.catalog,"l",repeatLocal), source: repeatLocal)
        await repeatLocalStore.next(source: repeatLocal)
        check(repeatLocalStore.error != nil && repeatLocalStore.tags.count == 20 && repeatLocal.localCalls.last?.2 == 2, "Repeated full local page is retryable and retains its page cursor")
        localRetry = true; await repeatLocalStore.next(source: repeatLocal)
        check(repeatLocalStore.tags.count == 21 && repeatLocalStore.error == nil, "Local retry resumes at the failing page")

        let repeatOnline = UnifiedTagSource(), repeatOnlineStore = TagDirectoryStore(debounceNanoseconds: 0)
        let fullOnline = (100...119).map { tag($0,"r\($0)") }
        var onlineRetry = false
        repeatOnline.online = { _,_,page in
            if page == 1 { return fullOnline }
            return onlineRetry ? [tag(120,"r120")] : fullOnline
        }
        await repeatOnlineStore.reload(key: key(.catalog,"r",repeatOnline), source: repeatOnline)
        await repeatOnlineStore.retryOnline(source: repeatOnline)
        check(repeatOnlineStore.onlineError != nil && repeatOnlineStore.tags.count == 20 && repeatOnline.onlineCalls.map(\.2) == [1,2], "Repeated full remote page stops with retryable error")
        onlineRetry = true; await repeatOnlineStore.retryOnline(source: repeatOnline)
        check(repeatOnlineStore.tags.count == 21 && repeatOnlineStore.onlineError == nil && repeatOnline.onlineCalls.last?.2 == 2, "Remote retry remains on the failed page")

        // Each lane scans at most three noise-heavy pages per call, then continues.
        let noiseSource = UnifiedTagSource(), noiseStore = TagDirectoryStore(debounceNanoseconds: 0)
        noiseSource.local = { _,_,cursor in
            let page = cursor?.page ?? 1
            return .init(items:(1...20).map { tag(page*100+$0,"!!") },next:.init(page:page+1))
        }
        noiseSource.online = { _,_,page in (1...20).map { tag(10_000+page*100+$0,"!!") } }
        await noiseStore.reload(key: key(.catalog,"",noiseSource), source: noiseSource)
        check(noiseSource.localCalls.count == 3 && noiseSource.onlineCalls.count == 3 && noiseStore.hiddenNoiseCount == 120 && !noiseStore.reachedEnd, "Local and online noise scans are each bounded to three pages")
        noiseSource.local = { _,_,_ in .init(items:[tag(999,"portrait")],next:nil) }
        noiseSource.online = { _,_,_ in [tag(1_999,"landscape")] }
        await noiseStore.next(source: noiseSource)
        check(noiseStore.tags.map(\.id) == [1_999,999] && noiseStore.reachedEnd, "Continuation advances each lane and reveals meaningful names")

        // A changed query/account or explicit cancel invalidates old responses and writes.
        let staleSource = UnifiedTagSource(), staleStore = TagDirectoryStore(debounceNanoseconds: 0)
        let oldGate=UnifiedTagGate(),oldStarted=UnifiedTagGate()
        staleSource.online = { _,keyword,_ in
            if keyword == "old" { oldStarted.open(); await oldGate.wait(); return [tag(300,"oldtag")] }
            return [tag(301,"newtag")]
        }
        let stale = Task { await staleStore.reload(key:key(.catalog,"old",staleSource),source:staleSource) }
        await oldStarted.wait()
        await staleStore.reload(key:key(.catalog,"new",staleSource),source:staleSource)
        oldGate.open(); await stale.value
        check(staleStore.tags.map(\.id) == [301] && staleSource.remembered.allSatisfy { $0.ids != [300] }, "Late old query cannot publish or remember after a newer query")

        let accountSource = UnifiedTagSource(), accountStore = TagDirectoryStore(debounceNanoseconds: 0)
        let accountGate=UnifiedTagGate(),accountStarted=UnifiedTagGate()
        accountSource.online = { _,keyword,_ in
            if keyword == "old" { accountStarted.open(); await accountGate.wait(); return [tag(310,"oldname")] }
            return [tag(311,"newname")]
        }
        let oldAccount = Task { await accountStore.reload(key:key(.catalog,"old",accountSource),source:accountSource) }
        await accountStarted.wait(); accountSource.lookupIdentity = "lookup-account-B"
        await accountStore.reload(key:key(.catalog,"new",accountSource),source:accountSource)
        accountGate.open(); await oldAccount.value
        check(accountStore.tags.map(\.id) == [311] && accountSource.remembered.allSatisfy { $0.ids != [310] }, "Account identity change rejects old results and old remember callbacks")

        let cancelSource = UnifiedTagSource(), cancelStore = TagDirectoryStore(debounceNanoseconds: 0)
        cancelSource.local = { _,_,_ in .init(items:[tag(400,"canary")],next:nil) }
        let cancelGate=UnifiedTagGate(),cancelStarted=UnifiedTagGate()
        cancelSource.online = { _,_,_ in cancelStarted.open(); await cancelGate.wait(); return [tag(401,"canopy")] }
        let canceled = Task { await cancelStore.reload(key:key(.catalog,"can",cancelSource),source:cancelSource) }
        await cancelStarted.wait(); cancelStore.cancel(); cancelGate.open(); await canceled.value
        check(cancelStore.tags.map(\.id) == [400] && cancelSource.remembered.isEmpty && !cancelStore.loading, "Cancel preserves loaded rows and blocks stale publish and remember")
        let callsAtCancel = cancelSource.onlineCalls.count
        await cancelStore.retryOnline(source:cancelSource); await cancelStore.next(source:cancelSource)
        check(cancelSource.onlineCalls.count == callsAtCancel && cancelSource.remembered.isEmpty, "Deferred retry and continuation remain inert after cancel until a fresh reload")

        let canceledEmptySource = UnifiedTagSource(), canceledEmptyStore = TagDirectoryStore(debounceNanoseconds:0)
        canceledEmptySource.local = { _,_,_ in .init(items:[],next:nil) }
        let canceledRemoteGate = UnifiedTagGate(), canceledRemoteStarted = UnifiedTagGate()
        canceledEmptySource.online = { _,_,_ in
            canceledRemoteStarted.open(); await canceledRemoteGate.wait(); return [tag(405,"reopened")]
        }
        let canceledEmptyReload = Task { await canceledEmptyStore.reload(key:key(.catalog,"re",canceledEmptySource),source:canceledEmptySource) }
        await canceledRemoteStarted.wait(); canceledEmptyStore.cancel(); canceledRemoteGate.open(); await canceledEmptyReload.value
        let callsBeforeReopen = canceledEmptySource.onlineCalls.count
        await canceledEmptyStore.reload(key:key(.catalog,"re",canceledEmptySource),source:canceledEmptySource)
        check(canceledEmptySource.onlineCalls.count == callsBeforeReopen + 1 && canceledEmptyStore.tags.map(\.id) == [405], "Canceled local-empty request cannot cache incomplete state; reopening refetches online")

        let debounceSource = UnifiedTagSource(), debounceStore = TagDirectoryStore(debounceNanoseconds: 20_000_000)
        debounceSource.local = { _,_,_ in .init(items:[tag(410,"waittag")],next:nil) }
        debounceSource.online = { _,_,_ in [tag(411,"waittag")] }
        let debouncedReload = Task { await debounceStore.reload(key:key(.catalog,"wait",debounceSource),source:debounceSource) }
        for _ in 0..<100 where debounceStore.tags.isEmpty { await Task.yield() }
        check(debounceStore.tags.map(\.id) == [410] && debounceSource.onlineCalls.isEmpty, "Debounce leaves immediate local results visible before online fetch")
        check(debounceStore.loading && debounceStore.pendingDebounce, "Combined loading remains active through the debounce interval")
        await debounceStore.next(source:debounceSource)
        check(debounceSource.onlineCalls.isEmpty, "next cannot bypass the pending debounce")
        debounceStore.cancel(); await debouncedReload.value
        check(debounceStore.tags.map(\.id) == [410] && debounceSource.onlineCalls.isEmpty && !debounceStore.loading, "Cancel during debounce preserves rows and prevents the delayed online request")

        print("UnifiedTagChecks: \(checks) regression assertions passed")
    }
}
