import Foundation
import SQLite3
import CryptoKit

private let tagSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private let tagSeedPrefixes = Array("abcdefghijklmnopqrstuvwxyz0123456789").map(String.init)

actor LocalTagDatabase {
    private let fileURL: URL
    private let maximumBytes: Int64
    private var connection: OpaquePointer?

    init(fileURL: URL, maximumBytes: Int64 = 128 * 1024 * 1024) {
        self.fileURL = fileURL
        self.maximumBytes = max(maximumBytes, 4096)
    }

    deinit {
        if let connection { sqlite3_close(connection) }
    }

    func stats() throws -> TagLibraryStats {
        let db = try openDatabase()
        var result = TagLibraryStats()
        result.stored = try scalarInt(db, "SELECT count(*) FROM tags")
        result.visible = try scalarInt(db, "SELECT count(*) FROM tags WHERE useful=1")
        result.common = try scalarInt(db, "SELECT count(*) FROM tags WHERE common_rank IS NOT NULL")
        result.completedPrefixes = try scalarInt(db, "SELECT count(*) FROM prefixes WHERE is_seed=1 AND completed_at IS NOT NULL")
        result.trackedPrefixes = try scalarInt(db, "SELECT count(*) FROM prefixes")
        result.lastCommonSync = try metaDate(db, key: "last_common_sync")
        result.lastSuccessfulSync = try metaDate(db, key: "last_successful_sync")
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard let size = attributes[.size] as? NSNumber else { throw LocalTagError.database }
            result.bytes = size.int64Value
        } catch { throw LocalTagError.database }
        return result
    }

    func query(prefix: String, common: Bool, after: LocalTagCursor?, context: String, limit: Int = 20) throws -> LocalTagPage {
        let db = try openDatabase()
        let normalizedPrefix = TagPolicy.normalize(prefix)
        let cursorContext = Self.cursorContext(context: context, prefix: normalizedPrefix, common: common)
        if let after, after.context != cursorContext { throw LocalTagError.contextChanged }
        let boundedLimit = min(max(limit, 1), 200)
        if common, after != nil { return LocalTagPage(items: [], next: nil) }

        let sql: String
        if common {
            sql = "SELECT id,name,nsfw_level FROM tags WHERE common_rank IS NOT NULL AND useful=1 AND normalized LIKE ? ESCAPE '\\' ORDER BY common_rank,id LIMIT ?"
        } else if after != nil {
            sql = "SELECT id,name,nsfw_level FROM tags WHERE useful=1 AND normalized LIKE ? ESCAPE '\\' AND (normalized > ? OR (normalized = ? AND id > ?)) ORDER BY normalized,id LIMIT ?"
        } else {
            sql = "SELECT id,name,nsfw_level FROM tags WHERE useful=1 AND normalized LIKE ? ESCAPE '\\' ORDER BY normalized,id LIMIT ?"
        }
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        try bind(prefixPattern(normalizedPrefix), at: 1, to: statement)
        var limitIndex: Int32 = 2
        if let after, !common {
            try bind(after.name, at: 2, to: statement)
            try bind(after.name, at: 3, to: statement)
            sqlite3_bind_int64(statement, 4, sqlite3_int64(after.id))
            limitIndex = 5
        }
        sqlite3_bind_int64(statement, limitIndex, sqlite3_int64(boundedLimit + (common ? 0 : 1)))
        var tags: [SearchTag] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            try check(code, db)
            guard let name = columnText(statement, 1) else { throw LocalTagError.database }
            let level = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, 2))
            tags.append(SearchTag(id: Int(sqlite3_column_int64(statement, 0)), name: name, nsfwLevel: level))
        }
        let hasMore = !common && tags.count > boundedLimit
        if hasMore { tags.removeLast() }
        let next = hasMore ? tags.last.map { LocalTagCursor(context: cursorContext, name: TagPolicy.normalize($0.name), id: $0.id) } : nil
        return LocalTagPage(items: tags, next: next)
    }

    func storeCommon(_ tags: [SearchTag], now: Date) throws {
        let db = try openDatabase()
        try validate(tags: tags, prefix: nil, pageSize: Int.max)
        try transaction(db) {
            try execute(db, "UPDATE tags SET common_rank=NULL")
            let sql = "INSERT INTO tags(id,name,normalized,nsfw_level,useful,common_rank) VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,normalized=excluded.normalized,nsfw_level=excluded.nsfw_level,useful=excluded.useful,common_rank=excluded.common_rank"
            let statement = try prepare(db, sql)
            defer { sqlite3_finalize(statement) }
            for (rank, tag) in tags.enumerated() {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                try bindTag(tag, rank: rank, statement: statement)
                try stepDone(statement, db)
            }
            try setMeta(db, key: "last_common_sync", date: now)
            try setMeta(db, key: "last_successful_sync", date: now)
        }
    }

    /// Search discoveries update the same ID index without advancing a bulk
    /// prefix's checkpoint or losing an existing common-tag rank.
    func mergeDiscovered(_ tags: [SearchTag], common: Bool, now: Date) throws {
        if common { try storeCommon(tags, now: now); return }
        let db = try openDatabase()
        try validate(tags: tags, prefix: nil, pageSize: 200)
        guard !tags.isEmpty else { return }
        try transaction(db) {
            let sql = "INSERT INTO tags(id,name,normalized,nsfw_level,useful,common_rank) VALUES(?,?,?,?,?,NULL) ON CONFLICT(id) DO UPDATE SET name=excluded.name,normalized=excluded.normalized,nsfw_level=COALESCE(excluded.nsfw_level,tags.nsfw_level),useful=excluded.useful"
            let statement = try prepare(db, sql)
            defer { sqlite3_finalize(statement) }
            for tag in tags {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                try bindTag(tag, rank: nil, statement: statement)
                try stepDone(statement, db)
            }
            try setMeta(db, key: "last_successful_sync", date: now)
        }
    }

    func nextWork(now: Date, refreshAfter: TimeInterval, preferredPrefix: String? = nil) throws -> TagPrefixWork? {
        let db = try openDatabase()
        let nowValue = now.timeIntervalSince1970
        if let preferredPrefix {
            let prefix = TagPolicy.normalize(preferredPrefix)
            guard !prefix.isEmpty, prefix.count <= 256 else { throw LocalTagError.invalidPage }
            return try transaction(db) {
                try execute(db, "INSERT OR IGNORE INTO prefixes(prefix,is_seed,page,cycle,last_attempt,completed_at) VALUES(?,0,1,1,0,NULL)", bindings: [.text(prefix)])
                let record = try prefixRecord(db, prefix: prefix)
                let cycle = record.completedAt == nil ? record.cycle : record.cycle + 1
                let page = record.completedAt == nil ? record.page : 1
                if cycle != record.cycle { try execute(db, "DELETE FROM page_signatures WHERE prefix=?", bindings: [.text(prefix)]) }
                try updatePrefix(db, prefix: prefix, page: page, cycle: cycle, lastAttempt: nowValue, completedAt: nil)
                return TagPrefixWork(prefix: prefix, page: page, cycle: cycle)
            }
        }

        return try transaction(db) {
            guard let record = try duePrefix(db, now: nowValue, refreshAfter: refreshAfter) else { return nil }
            let restarting = record.completedAt != nil
            let page = restarting ? 1 : record.page
            let cycle = restarting ? record.cycle + 1 : record.cycle
            if restarting { try execute(db, "DELETE FROM page_signatures WHERE prefix=?", bindings: [.text(record.prefix)]) }
            try updatePrefix(db, prefix: record.prefix, page: page, cycle: cycle, lastAttempt: nowValue, completedAt: nil)
            return TagPrefixWork(prefix: record.prefix, page: page, cycle: cycle)
        }
    }

    @discardableResult
    func commit(work: TagPrefixWork, tags: [SearchTag], pageSize: Int, now: Date) throws -> Bool {
        let db = try openDatabase()
        guard pageSize > 0 else { throw LocalTagError.invalidPage }
        try validate(tags: tags, prefix: work.prefix, pageSize: pageSize)
        return try transaction(db) {
            let record = try prefixRecord(db, prefix: work.prefix)
            guard record.page == work.page, record.cycle == work.cycle else { throw LocalTagError.contextChanged }
            let signature = Self.signature(tags.map(\.id))
            let duplicate = try scalarInt(db, "SELECT count(*) FROM page_signatures WHERE prefix=? AND cycle=? AND signature=?", bindings: [.text(work.prefix), .int(work.cycle), .text(signature)])
            guard duplicate == 0 else { throw LocalTagError.repeatedPage }
            let insert = try prepare(db, "INSERT INTO tags(id,name,normalized,nsfw_level,useful,common_rank) VALUES(?,?,?,?,?,NULL) ON CONFLICT(id) DO UPDATE SET name=excluded.name,normalized=excluded.normalized,nsfw_level=excluded.nsfw_level,useful=excluded.useful")
            defer { sqlite3_finalize(insert) }
            for tag in tags {
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                try bindTag(tag, rank: nil, statement: insert)
                try stepDone(insert, db)
            }
            try execute(db, "INSERT INTO page_signatures(prefix,cycle,signature) VALUES(?,?,?)", bindings: [.text(work.prefix), .int(work.cycle), .text(signature)])
            let finished = tags.count < pageSize
            let next = work.page + 1
            try updatePrefix(db, prefix: work.prefix, page: next, cycle: work.cycle, lastAttempt: now.timeIntervalSince1970, completedAt: finished ? now.timeIntervalSince1970 : nil)
            try setMeta(db, key: "last_successful_sync", date: now)
            return finished
        }
    }

    func reset() throws {
        let db = try openDatabase()
        try transaction(db) {
            try execute(db, "DELETE FROM page_signatures")
            try execute(db, "DELETE FROM prefixes")
            try execute(db, "DELETE FROM tags")
            try execute(db, "DELETE FROM metadata")
            try seedPrefixes(db)
        }
        try execute(db, "VACUUM")
    }

    private struct PrefixRecord {
        let prefix: String
        let page: Int
        let cycle: Int
        let lastAttempt: Double
        let completedAt: Double?
    }

    private func openDatabase() throws -> OpaquePointer {
        if let connection { return connection }
        do { try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { throw LocalTagError.database }
        var opened: OpaquePointer?
        let code = sqlite3_open_v2(fileURL.path, &opened, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let opened else { if let opened { sqlite3_close(opened) }; throw LocalTagError.database }
        sqlite3_busy_timeout(opened, 2500)
        do {
            guard try scalarInt(opened, "PRAGMA user_version") <= 1 else { throw LocalTagError.incompatibleSchema }
            try execute(opened, "PRAGMA journal_mode=DELETE")
            try execute(opened, "PRAGMA case_sensitive_like=ON")
            try execute(opened, "PRAGMA synchronous=FULL")
            try execute(opened, "PRAGMA foreign_keys=ON")
            try execute(opened, "PRAGMA page_size=4096")
            let maxPages = max(1, Int(maximumBytes / 4096))
            try execute(opened, "PRAGMA max_page_count=\(maxPages)")
            guard try scalarInt(opened, "PRAGMA max_page_count") <= maxPages else { throw LocalTagError.capacity }
            try initializeSchema(opened)
            connection = opened
            return opened
        } catch {
            let mapped = map(error, db: opened)
            sqlite3_close(opened)
            throw mapped
        }
    }

    private func initializeSchema(_ db: OpaquePointer) throws {
        let version = try scalarInt(db, "PRAGMA user_version")
        if version > 1 { throw LocalTagError.incompatibleSchema }
        if version == 1 {
            let check = try prepare(db, "PRAGMA quick_check")
            defer { sqlite3_finalize(check) }
            guard sqlite3_step(check) == SQLITE_ROW, columnText(check, 0) == "ok" else { throw LocalTagError.database }
            return
        }
        let existing = try scalarInt(db, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
        guard existing == 0 else { throw LocalTagError.incompatibleSchema }
        try transaction(db) {
            try execute(db, "CREATE TABLE tags(id INTEGER PRIMARY KEY CHECK(id>0),name TEXT NOT NULL,normalized TEXT NOT NULL,nsfw_level INTEGER,useful INTEGER NOT NULL CHECK(useful IN (0,1)),common_rank INTEGER)")
            try execute(db, "CREATE INDEX tags_normalized_id ON tags(normalized,id)")
            try execute(db, "CREATE INDEX tags_common_rank ON tags(common_rank,id)")
            try execute(db, "CREATE TABLE prefixes(prefix TEXT PRIMARY KEY,is_seed INTEGER NOT NULL,page INTEGER NOT NULL,cycle INTEGER NOT NULL,last_attempt REAL NOT NULL,completed_at REAL)")
            try execute(db, "CREATE INDEX prefixes_due ON prefixes(completed_at,last_attempt,prefix)")
            try execute(db, "CREATE TABLE page_signatures(prefix TEXT NOT NULL,cycle INTEGER NOT NULL,signature TEXT NOT NULL,PRIMARY KEY(prefix,cycle,signature))")
            try execute(db, "CREATE TABLE metadata(key TEXT PRIMARY KEY,value REAL NOT NULL)")
            try seedPrefixes(db)
            try execute(db, "PRAGMA user_version=1")
        }
    }

    private func seedPrefixes(_ db: OpaquePointer) throws {
        let statement = try prepare(db, "INSERT OR IGNORE INTO prefixes(prefix,is_seed,page,cycle,last_attempt,completed_at) VALUES(?,1,1,1,0,NULL)")
        defer { sqlite3_finalize(statement) }
        for prefix in tagSeedPrefixes {
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            try bind(prefix, at: 1, to: statement)
            try stepDone(statement, db)
        }
    }

    private func duePrefix(_ db: OpaquePointer, now: Double, refreshAfter: TimeInterval) throws -> PrefixRecord? {
        let statement = try prepare(db, "SELECT prefix,page,cycle,last_attempt,completed_at FROM prefixes WHERE completed_at IS NULL OR completed_at<=? ORDER BY last_attempt,prefix LIMIT 1")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, now - max(0, refreshAfter))
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        try check(code, db)
        return PrefixRecord(prefix: columnText(statement, 0) ?? "", page: Int(sqlite3_column_int64(statement, 1)), cycle: Int(sqlite3_column_int64(statement, 2)), lastAttempt: sqlite3_column_double(statement, 3), completedAt: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 4))
    }

    private func prefixRecord(_ db: OpaquePointer, prefix: String) throws -> PrefixRecord {
        let statement = try prepare(db, "SELECT prefix,page,cycle,last_attempt,completed_at FROM prefixes WHERE prefix=?")
        defer { sqlite3_finalize(statement) }
        try bind(prefix, at: 1, to: statement)
        let code = sqlite3_step(statement)
        guard code == SQLITE_ROW else { if code == SQLITE_DONE { throw LocalTagError.contextChanged }; try check(code, db); throw LocalTagError.database }
        return PrefixRecord(prefix: prefix, page: Int(sqlite3_column_int64(statement, 1)), cycle: Int(sqlite3_column_int64(statement, 2)), lastAttempt: sqlite3_column_double(statement, 3), completedAt: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 4))
    }

    private func updatePrefix(_ db: OpaquePointer, prefix: String, page: Int, cycle: Int, lastAttempt: Double, completedAt: Double?) throws {
        let statement = try prepare(db, "UPDATE prefixes SET page=?,cycle=?,last_attempt=?,completed_at=? WHERE prefix=?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sqlite3_int64(page)); sqlite3_bind_int64(statement, 2, sqlite3_int64(cycle))
        sqlite3_bind_double(statement, 3, lastAttempt)
        if let completedAt { sqlite3_bind_double(statement, 4, completedAt) } else { sqlite3_bind_null(statement, 4) }
        try bind(prefix, at: 5, to: statement)
        try stepDone(statement, db)
    }

    private func validate(tags: [SearchTag], prefix: String?, pageSize: Int) throws {
        guard tags.count <= pageSize else { throw LocalTagError.invalidPage }
        var ids = Set<Int>()
        for tag in tags {
            let normalized = TagPolicy.normalize(tag.name)
            guard tag.id > 0, !normalized.isEmpty, ids.insert(tag.id).inserted,
                  prefix.map({ normalized.hasPrefix($0) }) ?? true else { throw LocalTagError.invalidPage }
        }
    }

    private func bindTag(_ tag: SearchTag, rank: Int?, statement: OpaquePointer) throws {
        sqlite3_bind_int64(statement, 1, sqlite3_int64(tag.id))
        try bind(tag.name, at: 2, to: statement); try bind(TagPolicy.normalize(tag.name), at: 3, to: statement)
        if let level = tag.nsfwLevel { sqlite3_bind_int(statement, 4, Int32(level)) } else { sqlite3_bind_null(statement, 4) }
        sqlite3_bind_int(statement, 5, TagDirectoryQuality.includes(tag.name) ? 1 : 0)
        if let rank { sqlite3_bind_int64(statement, 6, sqlite3_int64(rank)) } else { sqlite3_bind_null(statement, 6) }
    }

    private func transaction<T>(_ db: OpaquePointer, _ body: () throws -> T) throws -> T {
        try execute(db, "BEGIN IMMEDIATE")
        do { let result = try body(); try execute(db, "COMMIT"); return result }
        catch { try? execute(db, "ROLLBACK"); throw map(error, db: db) }
    }

    private func execute(_ db: OpaquePointer, _ sql: String, bindings: [SQLiteValue] = []) throws {
        if bindings.isEmpty {
            var message: UnsafeMutablePointer<CChar>?
            let code = sqlite3_exec(db, sql, nil, nil, &message)
            if let message { sqlite3_free(message) }
            try check(code, db)
            return
        }
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() { try bind(value, at: Int32(offset + 1), to: statement) }
        try stepDone(statement, db)
    }

    private enum SQLiteValue { case text(String), int(Int), double(Double) }
    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
        let code = value.withCString { sqlite3_bind_text(statement, index, $0, -1, tagSQLiteTransient) }
        guard code == SQLITE_OK else { throw LocalTagError.database }
    }
    private func bind(_ value: SQLiteValue, at index: Int32, to statement: OpaquePointer) throws {
        switch value {
        case .text(let string): try bind(string, at: index, to: statement)
        case .int(let integer): sqlite3_bind_int64(statement, index, sqlite3_int64(integer))
        case .double(let double): sqlite3_bind_double(statement, index, double)
        }
    }
    private func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil), db)
        guard let statement else { throw LocalTagError.database }
        return statement
    }
    private func stepDone(_ statement: OpaquePointer, _ db: OpaquePointer) throws {
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else { try check(code, db); throw LocalTagError.database }
    }
    private func scalarInt(_ db: OpaquePointer, _ sql: String, bindings: [SQLiteValue] = []) throws -> Int {
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() { try bind(value, at: Int32(offset + 1), to: statement) }
        let code = sqlite3_step(statement)
        try check(code, db)
        guard code == SQLITE_ROW else { throw LocalTagError.database }
        return Int(sqlite3_column_int64(statement, 0))
    }
    private func metaDate(_ db: OpaquePointer, key: String) throws -> Date? {
        let statement = try prepare(db, "SELECT value FROM metadata WHERE key=?")
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, to: statement)
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        try check(code, db)
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }
    private func setMeta(_ db: OpaquePointer, key: String, date: Date) throws {
        try execute(db, "INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", bindings: [.text(key), .double(date.timeIntervalSince1970)])
    }
    private func check(_ code: Int32, _ db: OpaquePointer) throws {
        guard code == SQLITE_OK || code == SQLITE_ROW || code == SQLITE_DONE else {
            if code == SQLITE_FULL || sqlite3_errcode(db) == SQLITE_FULL { throw LocalTagError.capacity }
            if code == SQLITE_CORRUPT || code == SQLITE_NOTADB || sqlite3_errcode(db) == SQLITE_CORRUPT || sqlite3_errcode(db) == SQLITE_NOTADB { throw LocalTagError.database }
            throw LocalTagError.database
        }
    }
    private func map(_ error: Error, db: OpaquePointer) -> Error {
        if error is LocalTagError { return error }
        if sqlite3_errcode(db) == SQLITE_FULL { return LocalTagError.capacity }
        return LocalTagError.database
    }
    private func columnText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: text)
    }
    private func prefixPattern(_ prefix: String) -> String {
        let escaped = prefix.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return escaped + "%"
    }
    private static func cursorContext(context: String, prefix: String, common: Bool) -> String {
        "v1|\(common ? "common" : "all")|\(Data(context.utf8).base64EncodedString())|\(Data(prefix.utf8).base64EncodedString())"
    }
    private static func signature(_ ids: [Int]) -> String {
        let value = ids.sorted().map(String.init).joined(separator: ",")
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
