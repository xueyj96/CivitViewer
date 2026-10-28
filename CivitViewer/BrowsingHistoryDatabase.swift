import Foundation

actor BrowsingHistoryDatabase {
    private struct StoredArchive: Codable {
        let schemaVersion: Int
        let ownerKey: String
        var archive: HistoryArchive
    }

    private static let schemaVersion = 1
    private static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60
    private static let maximumRecords = 5_000
    private static let maximumAuthorNameLength = 160
    private static let maximumOwnerKeyLength = 256
    private static let maximumFilterLength = 160

    private let fileURL: URL
    private let ownerKey: String

    init(fileURL: URL, ownerKey: String) {
        self.fileURL = fileURL
        self.ownerKey = ownerKey
    }

    func load(now: Date = Date()) async throws -> HistoryArchive {
        try validateOwner()
        let current = try readArchive()
        let normalized = try normalizedArchive(current, now: now)
        if normalized != current { try persist(normalized) }
        return normalized
    }

    func record(_ record: HistoryRecord, now: Date = Date()) async throws -> HistoryArchive {
        try validateOwner()
        var archive = try readArchive()
        guard archive.recordingEnabled else { return archive }
        try Self.validate(record)
        var updated = record
        if updated.positionSeconds == nil, updated.durationSeconds == nil,
           updated.kind == .video,
           let previous = archive.records.first(where: { $0.id == updated.id && $0.kind == .video }) {
            updated.positionSeconds = previous.positionSeconds
            updated.durationSeconds = previous.durationSeconds
        }
        archive.records.removeAll { $0.id == updated.id }
        archive.records.append(updated)
        archive = try normalizedArchive(archive, now: now)
        try persist(archive)
        return archive
    }

    func progress(id: Int, position: Double, duration: Double, now: Date = Date()) async throws -> HistoryArchive {
        try validateOwner()
        var archive = try readArchive()
        guard archive.recordingEnabled else { return archive }
        guard position.isFinite, duration.isFinite, position >= 0, duration > 0, position <= duration else {
            throw BrowsingHistoryError.invalidProgress
        }
        if let index = archive.records.firstIndex(where: { $0.id == id && $0.kind == .video }) {
            archive.records[index].positionSeconds = position
            archive.records[index].durationSeconds = duration
        }
        archive = try normalizedArchive(archive, now: now)
        try persist(archive)
        return archive
    }

    func checkpoint(_ checkpoint: TimelineCheckpoint, now: Date = Date()) async throws -> HistoryArchive {
        try validateOwner()
        var archive = try readArchive()
        guard archive.recordingEnabled else { return archive }
        try Self.validate(checkpoint)
        var updated = checkpoint
        updated.updatedAt = now
        archive.checkpoints.removeAll { $0.lane == checkpoint.lane }
        archive.checkpoints.append(updated)
        archive = try normalizedArchive(archive, now: now)
        try persist(archive)
        return archive
    }

    func remove(ids: Set<Int>, now: Date = Date()) async throws -> HistoryArchive {
        try validateOwner()
        let original = try readArchive()
        var archive = try normalizedArchive(original, now: now)
        if ids.isEmpty {
            if archive != original { try persist(archive) }
            return archive
        }
        archive.records.removeAll { ids.contains($0.id) }
        archive.checkpoints = archive.checkpoints.compactMap { snapshot in
            guard !ids.contains(snapshot.focusedID) else { return nil }
            var updated = snapshot
            updated.ids.removeAll(where: { ids.contains($0) })
            return updated.ids.isEmpty ? nil : updated
        }
        archive = try normalizedArchive(archive, now: now)
        try persist(archive)
        return archive
    }

    func clear() async throws -> HistoryArchive {
        try validateOwner()
        var archive = try readArchive()
        archive.records = []
        archive.checkpoints = []
        try persist(archive)
        return archive
    }

    func setRecordingEnabled(_ enabled: Bool) async throws -> HistoryArchive {
        try validateOwner()
        let original = try readArchive()
        var archive = try normalizedArchive(original, now: Date())
        guard archive.recordingEnabled != enabled || archive != original else { return archive }
        archive.recordingEnabled = enabled
        try persist(archive)
        return archive
    }

    private func readArchive() throws -> HistoryArchive {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return HistoryArchive() }
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch { throw BrowsingHistoryError.corrupted }
        let stored: StoredArchive
        do { stored = try JSONDecoder().decode(StoredArchive.self, from: data) }
        catch { throw BrowsingHistoryError.corrupted }
        guard stored.schemaVersion == Self.schemaVersion else { throw BrowsingHistoryError.incompatibleSchema }
        guard stored.ownerKey == ownerKey else { throw BrowsingHistoryError.ownerMismatch }
        try Self.validateArchive(stored.archive)
        return stored.archive
    }

    private func normalizedArchive(_ input: HistoryArchive, now: Date) throws -> HistoryArchive {
        try Self.validateArchive(input)
        var result = input
        let cutoff = now.addingTimeInterval(-Self.retentionInterval)
        result.records.removeAll { $0.viewedAt < cutoff }
        result.records.sort {
            if $0.viewedAt != $1.viewedAt { return $0.viewedAt > $1.viewedAt }
            return $0.id > $1.id
        }
        if result.records.count > Self.maximumRecords { result.records = Array(result.records.prefix(Self.maximumRecords)) }
        result.checkpoints.removeAll { $0.updatedAt < cutoff }
        result.checkpoints.sort { $0.lane.rawValue < $1.lane.rawValue }
        return result
    }

    private func persist(_ archive: HistoryArchive) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do { data = try encoder.encode(StoredArchive(schemaVersion: Self.schemaVersion, ownerKey: ownerKey, archive: archive)) }
        catch { throw BrowsingHistoryError.writeFailed }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: fileURL.path)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var protectedURL = fileURL
            try protectedURL.setResourceValues(resourceValues)
        } catch { throw BrowsingHistoryError.writeFailed }
    }

    private func validateOwner() throws {
        guard !ownerKey.isEmpty, ownerKey.count <= Self.maximumOwnerKeyLength,
              !ownerKey.contains("://"), !ownerKey.contains("\n") else { throw BrowsingHistoryError.invalidOwner }
    }

    private static func validateArchive(_ archive: HistoryArchive) throws {
        var recordIDs = Set<Int>()
        for record in archive.records {
            try validate(record)
            guard recordIDs.insert(record.id).inserted else { throw BrowsingHistoryError.corrupted }
        }
        guard Set(archive.checkpoints.map(\.lane)).count == archive.checkpoints.count else { throw BrowsingHistoryError.corrupted }
        for checkpoint in archive.checkpoints { try validate(checkpoint) }
    }

    private static func validate(_ record: HistoryRecord) throws {
        guard record.id > 0, record.creatorID.map({ $0 > 0 }) ?? true,
              record.authorName.map({ $0.count <= maximumAuthorNameLength && !$0.contains("://") && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) ?? true,
              record.viewedAt.timeIntervalSince1970.isFinite,
              record.positionSeconds.map({ $0.isFinite && $0 >= 0 }) ?? true,
              record.durationSeconds.map({ $0.isFinite && $0 > 0 }) ?? true,
              !(record.positionSeconds != nil && record.durationSeconds != nil && record.positionSeconds! > record.durationSeconds!) else {
            throw BrowsingHistoryError.invalidRecord
        }
    }

    private static func validate(_ checkpoint: TimelineCheckpoint) throws {
        let filter = checkpoint.filter
        let values = [filter.sort, filter.period, filter.baseModel]
        guard checkpoint.ids.count <= 60, !checkpoint.ids.isEmpty,
              checkpoint.ids.allSatisfy({ $0 > 0 }), Set(checkpoint.ids).count == checkpoint.ids.count,
              checkpoint.ids.contains(checkpoint.focusedID), checkpoint.focusedID > 0,
              checkpoint.updatedAt.timeIntervalSince1970.isFinite,
              values.allSatisfy({ $0.count <= maximumFilterLength && !$0.contains("://") && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw BrowsingHistoryError.invalidCheckpoint
        }
    }
}
