import Foundation
import Combine

@MainActor final class OfflineLibrary {
    static let shared = OfflineLibrary()
    var metadataNetworkConnected: Bool { true }
    var unmeteredMetadataNetwork: Bool { true }
}

@MainActor private final class TagSourceFake: TagLibrarySource {
    let tagLibraryOwnerID: Int?
    let tagLibraryIdentity: String
    var commonCalls = 0
    var pageCalls: [(prefix: String, page: Int, limit: Int)] = []

    init(ownerID: Int) {
        tagLibraryOwnerID = ownerID
        tagLibraryIdentity = "fixture-owner-\(ownerID)"
    }
    func remoteTagPage(prefix: String, page: Int, limit: Int) async throws -> [SearchTag] {
        pageCalls.append((prefix, page, limit))
        return [SearchTag(id: tagLibraryOwnerID! + 1_000, name: prefix + "eta", nsfwLevel: 1)]
    }
    func remoteCommonTags() async throws -> [SearchTag] { commonCalls += 1; return [] }
}

@main struct LocalTagBindingChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            precondition(condition(), message)
        }
        func expectContextChanged(_ operation: () async throws -> Void) async throws {
            do { try await operation(); preconditionFailure("Expected stale-owner context rejection") }
            catch let error as LocalTagError {
                switch error {
                case .contextChanged: checks += 1
                default: preconditionFailure("Expected contextChanged, got \(error)")
                }
            }
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tag-binding-checks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = LocalTagLibrary(rootURL: root)
        library.setActive(true)
        let sourceA = TagSourceFake(ownerID: 101), sourceB = TagSourceFake(ownerID: 202)
        await library.bind(ownerID: 101)
        let localA = try await library.page(ownerID: 101, keyword: "", common: false, cursor: nil)
        check(localA.items.isEmpty && sourceA.pageCalls.isEmpty && sourceA.commonCalls == 0, "Same-owner local read does not invoke the remote source")

        await library.bind(ownerID: 202)
        let localB = try await library.page(ownerID: 202, keyword: "", common: false, cursor: nil)
        check(localB.items.isEmpty && sourceB.pageCalls.isEmpty && library.stats.stored == 0, "Binding B selects its isolated empty local database")

        try await expectContextChanged {
            _ = try await library.page(ownerID: 101, keyword: "", common: false, cursor: nil)
        }
        let canceledOldPage = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await library.page(ownerID: 101, keyword: "", common: false, cursor: nil)
        }
        do { _ = try await canceledOldPage.value; preconditionFailure("Canceled old-owner read must throw") }
        catch is CancellationError { checks += 1 }
        catch { preconditionFailure("Expected cancellation, got \(error)") }

        // A pre-canceled bind must not switch the shared Facade away from B.
        let canceledBindA = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await library.bind(ownerID: 101)
        }
        await canceledBindA.value
        let afterCanceledBind = try await library.page(ownerID: 202, keyword: "", common: false, cursor: nil)
        check(afterCanceledBind.items.isEmpty, "Canceled bind A cannot interrupt or replace the current B binding")

        await library.reset(ownerID: 101)
        check(library.stats.stored == 0 && sourceB.pageCalls.isEmpty, "Stale A reset is ignored while B remains bound")

        // A user pause blocks automatic scheduling; explicit manual work resumes it.
        library.pause(reason: "paused by test", userInitiated: true)
        library.requestSync(source: sourceB, prefix: "p", manual: false)
        await library.waitForSync()
        check(!library.busy && sourceB.commonCalls == 0 && sourceB.pageCalls.isEmpty, "Automatic request does not resume a user-paused sync")

        library.requestSync(source: sourceB, prefix: "p", manual: true)
        await library.waitForSync()
        check(sourceB.commonCalls == 1 && sourceB.pageCalls.count == 1, "Manual sync performs one common read and one preferred prefix request")
        check(sourceB.pageCalls.first?.prefix == "p" && sourceB.pageCalls.first?.page == 1 && sourceB.pageCalls.first?.limit == 200, "Preferred prefix uses its first bounded batch page")
        let localAfterSync = try await library.page(ownerID: 202, keyword: "p", common: false, cursor: nil)
        check(localAfterSync.items.map(\.id) == [1_202] && localAfterSync.items.first?.name == "peta", "B local read returns only the row saved by its preferred sync")
        await library.reset(ownerID: 101)
        let afterOldReset = try await library.page(ownerID: 202, keyword: "p", common: false, cursor: nil)
        check(afterOldReset.items.map(\.id) == [1_202] && library.stats.stored == 1, "Old A reset cannot clear B's already-synchronized database")
        check(sourceA.commonCalls == 0 && sourceA.pageCalls.isEmpty && library.stats.stored == 1, "Stale owner A never receives a sync and B owns the persisted row")

        try await expectContextChanged {
            try await library.rememberDiscovered(ownerID: 101, tags: [.init(id: 901, name: "cat")], common: false)
        }
        try await library.rememberDiscovered(ownerID: 202, tags: [.init(id: 902, name: "cat", nsfwLevel: 4)], common: true)
        try await library.rememberDiscovered(ownerID: 202, tags: [.init(id: 902, name: "cathedral"), .init(id: 903, name: "cafe", nsfwLevel: 1)], common: false)
        let discovered = try await library.page(ownerID: 202, keyword: "ca", common: false, cursor: nil)
        check(discovered.items.map(\.id) == [903, 902], "Online discoveries reuse canonical IDs and current sorted local lookup")
        let ranked = try await library.page(ownerID: 202, keyword: "", common: true, cursor: nil)
        check(ranked.items.map(\.id) == [902] && ranked.items.first?.nsfwLevel == 4, "Search update preserves common rank and previously known rating")
        let discoveriesDB = LocalTagDatabase(fileURL: root.appendingPathComponent("discovery-checkpoints.sqlite"))
        let beforeWork = try await discoveriesDB.nextWork(now: Date(), refreshAfter: 86400, preferredPrefix: "c")!
        try await discoveriesDB.mergeDiscovered([.init(id: 21, name: "city")], common: false, now: Date())
        let afterWork = try await discoveriesDB.nextWork(now: Date(), refreshAfter: 86400, preferredPrefix: "c")!
        check(beforeWork == afterWork, "Interactive lookup cannot advance bulk synchronization checkpoints")
        try await discoveriesDB.storeCommon([.init(id: 21, name: "city")], now: Date())
        try await discoveriesDB.mergeDiscovered([], common: true, now: Date())
        let nowCommon = try await discoveriesDB.query(prefix: "", common: true, after: nil, context: "discovery")
        let nowAll = try await discoveriesDB.query(prefix: "", common: false, after: nil, context: "discovery")
        check(nowCommon.items.isEmpty && nowAll.items.map(\.id) == [21], "Empty fresh common snapshot clears ranks while retaining tag metadata")
        let oldDatabase = try await library.page(ownerID: 202, keyword: "ca", common: false, cursor: nil)
        check(oldDatabase.items.map(\.id) == [903, 902], "Independent discovery checkpoint tests preserve current owner's facade")
        print("LocalTagBindingChecks: \(checks) regression assertions passed")
    }
}
