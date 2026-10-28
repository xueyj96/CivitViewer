import Foundation
import SQLite3

@main struct LocalTagDatabaseChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tag-library-checks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func url(_ name: String) -> URL { root.appendingPathComponent(name) }
        func tag(_ id: Int, _ name: String, _ level: Int? = 1) -> SearchTag { SearchTag(id: id, name: name, nsfwLevel: level) }
        func sameError(_ lhs: LocalTagError, _ rhs: LocalTagError) -> Bool {
            switch (lhs, rhs) {
            case (.database,.database),(.capacity,.capacity),(.invalidPage,.invalidPage),(.repeatedPage,.repeatedPage),(.contextChanged,.contextChanged),(.incompatibleSchema,.incompatibleSchema): true
            default: false
            }
        }
        func expectError(_ expected: LocalTagError, _ body: () async throws -> Void) async throws {
            do { try await body(); preconditionFailure("Expected error: \(expected)") }
            catch let error as LocalTagError { precondition(sameError(error, expected), "Expected \(expected), got \(error)") }
        }

        let path = url("catalog.sqlite")
        var first: LocalTagDatabase? = LocalTagDatabase(fileURL: path)
        var stats = try await first!.stats()
        precondition(stats.stored == 0 && stats.visible == 0 && stats.trackedPrefixes == 36 && stats.completedPrefixes == 0, "New database seeds the bounded 36-prefix schedule")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let work1 = try await first!.nextWork(now: now, refreshAfter: 3600, preferredPrefix: " A ")!
        precondition(work1 == TagPrefixWork(prefix: "a", page: 1, cycle: 1), "Preferred prefix normalizes and begins a fresh cycle")
        let completed1 = try await first!.commit(work: work1, tags: [tag(1,"alpha"),tag(2,"amber")], pageSize: 2, now: now)
        precondition(!completed1, "A full page checkpoints continuation, not completion")

        // A second actor proves the page and cycle survive closing/reopening.
        first = nil // Close the initial actor connection before reopening the database.
        let reopened = LocalTagDatabase(fileURL: path)
        let work2 = try await reopened.nextWork(now: now.addingTimeInterval(5), refreshAfter: 3600, preferredPrefix: "a")!
        precondition(work2 == TagPrefixWork(prefix: "a", page: 2, cycle: 1), "Restart resumes the incomplete prefix at its stored page")
        let completed2 = try await reopened.commit(work: work2, tags: [tag(1,"apple",2),tag(3,"apricot")], pageSize: 2, now: now.addingTimeInterval(5))
        precondition(!completed2, "A full resumed page retains its checkpoint")
        let work3 = try await reopened.nextWork(now: now.addingTimeInterval(6), refreshAfter: 3600, preferredPrefix: "a")!
        precondition(work3.page == 3 && work3.cycle == 1, "Reopened full page advances within the same cycle")
        let completed3 = try await reopened.commit(work: work3, tags: [tag(4,"avocado")], pageSize: 2, now: now.addingTimeInterval(6))
        precondition(completed3, "Short page completes its prefix cycle")
        stats = try await reopened.stats()
        precondition(stats.stored == 4 && stats.visible == 4 && stats.lastSuccessfulSync == now.addingTimeInterval(6), "Overlapping IDs upsert names and successful sync time without duplicate rows")
        precondition(stats.completedPrefixes == 1 && stats.trackedPrefixes == 36, "Stats count completed built-in prefixes and report all tracked work")
        let renamed = try await reopened.query(prefix: "app", common: false, after: nil, context: "browse")
        precondition(renamed.items.map(\.id) == [1] && renamed.items.first?.name == "apple", "ID upsert exposes the newest label and quality fields")

        // Invalid pages roll back and leave the exact work token reusable.
        let invalidWork = try await reopened.nextWork(now: now.addingTimeInterval(10), refreshAfter: 10, preferredPrefix: "x")!
        try await expectError(.invalidPage) {
            _ = try await reopened.commit(work: invalidWork, tags: [tag(8,"wrong-prefix")], pageSize: 20, now: now)
        }
        let retriedWork = try await reopened.nextWork(now: now.addingTimeInterval(11), refreshAfter: 10, preferredPrefix: "x")!
        precondition(retriedWork == invalidWork, "Rejected page does not advance or change cycle")
        _ = try await reopened.commit(work: invalidWork, tags: [tag(8,"xylophone")], pageSize: 20, now: now.addingTimeInterval(12))
        stats = try await reopened.stats()
        precondition(stats.stored == 5, "Valid retry commits atomically after invalid input")

        // Identical ID sets are rejected anywhere in the same cycle, even on another page.
        let repeat1 = try await reopened.nextWork(now: now.addingTimeInterval(20), refreshAfter: 0, preferredPrefix: "b")!
        _ = try await reopened.commit(work: repeat1, tags: [tag(10,"bird"),tag(11,"blue")], pageSize: 2, now: now.addingTimeInterval(20))
        let repeat2 = try await reopened.nextWork(now: now.addingTimeInterval(21), refreshAfter: 0, preferredPrefix: "b")!
        precondition(repeat2.page == 2 && repeat2.cycle == repeat1.cycle, "Full pages resume the same cycle")
        try await expectError(.repeatedPage) {
            _ = try await reopened.commit(work: repeat2, tags: [tag(10,"bird"),tag(11,"blue")], pageSize: 2, now: now.addingTimeInterval(21))
        }
        let afterRepeat = try await reopened.nextWork(now: now.addingTimeInterval(22), refreshAfter: 0, preferredPrefix: "b")!
        precondition(afterRepeat == repeat2, "Repeated-page rejection retains the failing checkpoint")
        _ = try await reopened.commit(work: repeat2, tags: [tag(12,"bunny")], pageSize: 2, now: now.addingTimeInterval(23))

        // Automatic scheduling rotates by claim time; a preferred completed prefix forces a new cycle.
        let scheduled = try await reopened.nextWork(now: now.addingTimeInterval(30), refreshAfter: 3600)!
        precondition(scheduled.prefix != "a" && scheduled.prefix != "x" && scheduled.prefix != "b", "Automatic work selects another due seed prefix")
        let manualAgain = try await reopened.nextWork(now: now.addingTimeInterval(31), refreshAfter: 99_999, preferredPrefix: "a")!
        precondition(manualAgain == TagPrefixWork(prefix: "a", page: 1, cycle: 2), "Manual recheck starts a new cycle even before automatic expiry")

        // Common replacement preserves other IDs, and keyset pagination tolerates inserts.
        try await reopened.storeCommon([tag(100,"item01"),tag(101,"item02"),tag(102,"item03")], now: now.addingTimeInterval(40))
        let common = try await reopened.query(prefix: "item", common: true, after: nil, context: "common", limit: 999)
        precondition(common.items.map(\.id) == [100,101,102] && common.next == nil, "Common list follows stored rank and is bounded to one page")
        let firstSlice = try await reopened.query(prefix: "item", common: false, after: nil, context: "browse", limit: 2)
        precondition(firstSlice.items.map(\.id) == [100,101] && firstSlice.next?.id == 101, "Normal catalog returns a keyset cursor after limit+1")
        try await reopened.storeCommon([tag(100,"item01"),tag(101,"item02"),tag(105,"item025"),tag(102,"item03")], now: now.addingTimeInterval(41))
        let insertedSlice = try await reopened.query(prefix: "item", common: false, after: firstSlice.next, context: "browse", limit: 3)
        precondition(insertedSlice.items.map(\.id) == [105,102], "Insertion after the cursor is visible without repeating earlier IDs")
        try await expectError(.contextChanged) {
            _ = try await reopened.query(prefix: "item", common: false, after: firstSlice.next, context: "different", limit: 3)
        }
        stats = try await reopened.stats()
        precondition(stats.stored >= 7 && stats.common == 4 && stats.lastCommonSync == now.addingTimeInterval(41), "Common replacement changes rank atomically and preserves non-common rows")

        let unicodeWork = try await reopened.nextWork(now: now.addingTimeInterval(50), refreshAfter: 0, preferredPrefix: "猫")!
        _ = try await reopened.commit(work: unicodeWork, tags: [tag(200,"猫咪风格")], pageSize: 20, now: now.addingTimeInterval(50))
        let unicode = try await reopened.query(prefix: "猫", common: false, after: nil, context: "unicode")
        precondition(unicode.items.map(\.id) == [200], "Unicode prefixes round-trip through normalized SQLite matching")

        // Known unhelpful names remain stored for future quality-rule changes but are hidden by default.
        try await reopened.storeCommon([tag(300,"90s"),tag(301,"landscape style")], now: now.addingTimeInterval(60))
        stats = try await reopened.stats()
        let quality = try await reopened.query(prefix: "", common: false, after: nil, context: "quality", limit: 20)
        precondition(stats.stored >= 2 && stats.visible == stats.stored - 1 && quality.items.allSatisfy { TagDirectoryQuality.includes($0.name) }, "Noise records remain stored while quality filtering controls visibility")

        try await reopened.reset()
        stats = try await reopened.stats()
        precondition(stats.stored == 0 && stats.completedPrefixes == 0 && stats.trackedPrefixes == 36 && FileManager.default.fileExists(atPath: path.path), "Reset clears this database and reseeds its schedule without deleting the database file")

        // Version and corruption failures retain their original files.
        let incompatibleURL = url("future.sqlite")
        var raw: OpaquePointer?
        precondition(sqlite3_open(incompatibleURL.path, &raw) == SQLITE_OK)
        sqlite3_exec(raw, "PRAGMA user_version=99", nil, nil, nil); sqlite3_close(raw)
        let incompatible = LocalTagDatabase(fileURL: incompatibleURL)
        do { _ = try await incompatible.stats(); preconditionFailure("Expected incompatible schema") }
        catch let error as LocalTagError { precondition(sameError(error, .incompatibleSchema) && FileManager.default.fileExists(atPath: incompatibleURL.path), "Future schema is rejected without deleting its file") }
        let damagedURL = url("damaged.sqlite"); try Data("not a sqlite database".utf8).write(to: damagedURL)
        let damaged = LocalTagDatabase(fileURL: damagedURL)
        do { _ = try await damaged.stats(); preconditionFailure("Expected corrupt database failure") }
        catch { precondition(FileManager.default.fileExists(atPath: damagedURL.path), "Corrupt database remains in place for recovery") }

        // A small page budget produces SQLITE_FULL as a capacity result and rolls back.
        let limited = LocalTagDatabase(fileURL: url("limited.sqlite"), maximumBytes: 64 * 1024)
        _ = try await limited.stats()
        let large = (1...3_000).map { tag(10_000 + $0, "capacity-label-\($0)-" + String(repeating: "q", count: 80)) }
        try await expectError(.capacity) { try await limited.storeCommon(large, now: now) }
        let limitedStats = try await limited.stats()
        precondition(limitedStats.stored == 0, "Capacity failure rolls back the common replacement")

        // Bounded synthetic scale sample: no real catalog data or network access.
        let scale = LocalTagDatabase(fileURL: url("scale.sqlite"), maximumBytes: 128 * 1024 * 1024)
        let beforeGrowth = try await scale.stats()
        let fixtures = (0..<100_000).map { tag(1_000_000 + $0, String(format: "tag%06d", $0), $0 % 4) }
        let scaleStart = DispatchTime.now().uptimeNanoseconds
        try await scale.storeCommon(fixtures, now: now)
        let commonScale = try await scale.query(prefix: "tag", common: true, after: nil, context: "scale-common", limit: 999)
        precondition(commonScale.items.count == 200 && commonScale.items.first?.id == 1_000_000, "Common mode caps the ranked one-page result at 200")
        var cursor: LocalTagCursor?
        var found = 0
        let queryStart = DispatchTime.now().uptimeNanoseconds
        repeat {
            let page = try await scale.query(prefix: "tag099", common: false, after: cursor, context: "scale", limit: 20)
            found += page.items.count; cursor = page.next
        } while cursor != nil
        let queryMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - queryStart) / 1_000_000
        let writeMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - scaleStart) / 1_000_000 - queryMilliseconds
        let scaleStats = try await scale.stats()
        let actualSize = (try FileManager.default.attributesOfItem(atPath: url("scale.sqlite").path)[.size] as! NSNumber).int64Value
        precondition(scaleStats.bytes == actualSize && scaleStats.bytes > beforeGrowth.bytes, "Disk use reflects current file size after a previously observed database grows")
        precondition(scaleStats.stored == 100_000 && found == 1_000 && scaleStats.bytes <= 128 * 1024 * 1024, "100k local records stay within configured storage and prefix query coverage")
        print(String(format: "LocalTagDatabaseChecks: 23 checks passed; synthetic=100000 rows; query=%.1fms; write=%.1fms; bytes=%lld", queryMilliseconds, writeMilliseconds, scaleStats.bytes))
    }
}
