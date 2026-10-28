import Foundation

private struct HistoryFixtureEnvelope: Codable {
    let schemaVersion: Int
    let ownerKey: String
    let archive: HistoryArchive
}

@main struct BrowsingHistoryChecks {
    static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            precondition(condition(), message)
        }
        func sameError(_ error: BrowsingHistoryError, _ kind: String) -> Bool {
            switch (error, kind) {
            case (.invalidOwner,"owner"),(.ownerMismatch,"mismatch"),(.incompatibleSchema,"schema"),(.corrupted,"corrupt"),(.invalidRecord,"record"),(.invalidProgress,"progress"),(.invalidCheckpoint,"checkpoint"),(.writeFailed,"write"): true
            default: false
            }
        }
        func expectError(_ kind: String, _ operation: () async throws -> Void) async throws {
            do { try await operation(); preconditionFailure("Expected history error \(kind)") }
            catch let error as BrowsingHistoryError {
                checks += 1
                precondition(sameError(error, kind), "Expected \(kind), got \(error)")
            }
        }
        func makeRecord(_ id: Int, kind: MediaKind = .video, date: Date, author: String? = "fixture", creator: Int? = 7,
                        position: Double? = nil, duration: Double? = nil) -> HistoryRecord {
            HistoryRecord(id: id, kind: kind, authorName: author, creatorID: creator, viewedAt: date,
                          positionSeconds: position, durationSeconds: duration)
        }
        func makeCheckpoint(_ lane: HistoryLane, ids: [Int], focus: Int, date: Date, filter: FeedFilter = FeedFilter()) -> TimelineCheckpoint {
            TimelineCheckpoint(lane: lane, filter: filter, ids: ids, focusedID: focus, updatedAt: date)
        }
        func data(_ envelope: HistoryFixtureEnvelope) throws -> Data {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(envelope)
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browsing-history-checks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func file(_ name: String) -> URL { root.appendingPathComponent(name) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        // Unique-ID upsert, newest-first ordering, and retention window.
        let primaryURL = file("history.json"), database = BrowsingHistoryDatabase(fileURL: primaryURL, ownerKey: "owner-A")
        _ = try await database.record(makeRecord(1, date: now.addingTimeInterval(-20)), now: now)
        _ = try await database.record(makeRecord(2, kind: .image, date: now.addingTimeInterval(-10)), now: now)
        let upserted = try await database.record(makeRecord(1, date: now, author: "renamed", creator: 8), now: now)
        check(upserted.records.map(\.id) == [1,2] && upserted.records.first?.authorName == "renamed", "Record upsert is unique by work ID and sorts newest first")
        let kept = try await database.record(makeRecord(3, date: now.addingTimeInterval(-29 * 86_400)), now: now)
        check(kept.records.contains(where: { $0.id == 3 }), "Records within the 30-day window are retained")
        let afterWindow = try await database.load(now: now.addingTimeInterval(2 * 86_400))
        check(!afterWindow.records.contains(where: { $0.id == 3 }), "Expired records are pruned on load")

        // Playback progress is finite, video-only, and independent of viewedAt.
        _ = try await database.record(makeRecord(10, date: now, position: 10, duration: 100), now: now)
        let progress = try await database.progress(id: 10, position: 98, duration: 100, now: now.addingTimeInterval(5))
        let progressed = progress.records.first(where: { $0.id == 10 })!
        check(progressed.positionSeconds == 98 && progressed.durationSeconds == 100 && progressed.viewedAt == now, "Progress updates do not change the original viewedAt")
        let revisited = try await database.record(makeRecord(10, date: now.addingTimeInterval(10)), now: now.addingTimeInterval(10))
        let revisitedVideo = revisited.records.first(where: { $0.id == 10 })!
        check(revisitedVideo.positionSeconds == 98 && revisitedVideo.durationSeconds == 100 && revisitedVideo.viewedAt == now.addingTimeInterval(10), "A fresh visit refreshes viewedAt while preserving existing progress")
        _ = try await database.record(makeRecord(11, kind: .image, date: now), now: now)
        let imageProgress = try await database.progress(id: 11, position: 4, duration: 50, now: now)
        check(imageProgress.records.first(where: { $0.id == 11 })?.positionSeconds == nil, "Still-image rows do not acquire video progress")
        try await expectError("progress") { _ = try await database.progress(id: 10, position: .infinity, duration: 100, now: now) }
        try await expectError("progress") { _ = try await database.progress(id: 10, position: -1, duration: 100, now: now) }
        check(PlaybackResumePolicy.position(position: 25, duration: 100) == 25, "Resume helper returns an ordinary finite seek position")
        check(PlaybackResumePolicy.position(position: 98, duration: 100) == nil && PlaybackResumePolicy.position(position: 99, duration: 100) == nil && PlaybackResumePolicy.position(position: 88, duration: 90) == nil, "Near-end and 98-percent progress do not resume")
        check(PlaybackResumePolicy.position(position: 10, duration: .infinity) == nil && PlaybackResumePolicy.position(position: 1, duration: 0) == nil && PlaybackResumePolicy.position(position: .nan, duration: 100) == nil, "Resume helper rejects non-finite or non-positive values")

        // Checkpoints allow unseen IDs, have bounded unique IDs, and prune correctly.
        let checkpointed = try await database.checkpoint(makeCheckpoint(.recommendation, ids: [70,71,72], focus: 71, date: now), now: now.addingTimeInterval(3))
        check(checkpointed.checkpoints.count == 1 && checkpointed.checkpoints[0].updatedAt == now.addingTimeInterval(3), "Checkpoint accepts unseen neighboring IDs and timestamps the save")
        try await expectError("checkpoint") { _ = try await database.checkpoint(makeCheckpoint(.following, ids: [1,1], focus: 1, date: now), now: now) }
        try await expectError("checkpoint") { _ = try await database.checkpoint(makeCheckpoint(.following, ids: [1,2], focus: 3, date: now), now: now) }
        let prunedCheckpoint = try await database.remove(ids: [70], now: now)
        check(prunedCheckpoint.checkpoints.first?.ids == [71,72], "Removing a neighboring work removes it from the snapshot")
        let removedFocus = try await database.remove(ids: [71], now: now)
        check(removedFocus.checkpoints.isEmpty, "Removing the focused work drops its checkpoint")
        let oldCheckpoint = makeCheckpoint(.following, ids: [80,81], focus: 80, date: now.addingTimeInterval(-31 * 86_400))
        _ = try await database.checkpoint(oldCheckpoint, now: oldCheckpoint.updatedAt)
        let expiredCheckpoint = try await database.load(now: now)
        check(expiredCheckpoint.checkpoints.isEmpty, "Snapshots older than 30 days expire")

        // Recording opt-out makes writes no-ops; re-enabling resumes normal behavior.
        let disabled = try await database.setRecordingEnabled(false)
        let disabledRecord = try await database.record(makeRecord(99, date: now), now: now)
        let disabledProgress = try await database.progress(id: 10, position: 15, duration: 100, now: now)
        let disabledCheckpoint = try await database.checkpoint(makeCheckpoint(.following, ids: [90], focus: 90, date: now), now: now)
        check(!disabled.recordingEnabled && disabledRecord == disabled && disabledProgress == disabled && disabledCheckpoint == disabled, "Disabled record, progress, and checkpoint writes are no-ops")
        let enabled = try await database.setRecordingEnabled(true)
        check(enabled.recordingEnabled, "Recording preference can be enabled again")

        // The archive is bounded at 5,000 unique works; read repairs an oversized valid fixture.
        let capURL = file("cap.json")
        let capRecords = (1...5_001).map { index in makeRecord(index, date: now.addingTimeInterval(-Double(index))) }
        try data(HistoryFixtureEnvelope(schemaVersion: 1, ownerKey: "owner-cap", archive: HistoryArchive(records: capRecords))).write(to: capURL)
        let capped = try await BrowsingHistoryDatabase(fileURL: capURL, ownerKey: "owner-cap").load(now: now)
        check(capped.records.count == 5_000 && capped.records.first?.id == 1 && capped.records.last?.id == 5_000, "Retention caps unique work history at the newest 5,000 IDs")

        // Strict owner/schema/corruption failures leave the source file byte-for-byte intact.
        let ownerBytes = try Data(contentsOf: primaryURL)
        try await expectError("mismatch") { _ = try await BrowsingHistoryDatabase(fileURL: primaryURL, ownerKey: "owner-B").load(now: now) }
        let ownerBytesAfter = try Data(contentsOf: primaryURL)
        check(ownerBytesAfter == ownerBytes, "Wrong owner cannot rewrite the existing history file")
        let schemaURL = file("future.json")
        let schemaBytes = try data(HistoryFixtureEnvelope(schemaVersion: 88, ownerKey: "owner-A", archive: HistoryArchive()))
        try schemaBytes.write(to: schemaURL)
        try await expectError("schema") { _ = try await BrowsingHistoryDatabase(fileURL: schemaURL, ownerKey: "owner-A").load(now: now) }
        let schemaBytesAfter = try Data(contentsOf: schemaURL)
        check(schemaBytesAfter == schemaBytes, "Unknown schema is rejected without overwriting its file")
        let damagedURL = file("damaged.json"); let damagedBytes = Data("{not-json".utf8); try damagedBytes.write(to: damagedURL)
        try await expectError("corrupt") { _ = try await BrowsingHistoryDatabase(fileURL: damagedURL, ownerKey: "owner-A").load(now: now) }
        let damagedBytesAfter = try Data(contentsOf: damagedURL)
        check(damagedBytesAfter == damagedBytes, "Corrupt data remains untouched for recovery")

        // Serialized records contain no URLs, cursors, or tokens; clear touches only this file.
        let json = String(decoding: try Data(contentsOf: primaryURL), as: UTF8.self).lowercased()
        check(!json.contains("https://") && !json.contains("\"url\"") && !json.contains("cursor") && !json.contains("token"), "History JSON contains no media addresses or cursors")
        let unrelated = file("offline-favorites.marker"); try Data("preserve".utf8).write(to: unrelated)
        let cleared = try await database.clear()
        check(cleared.records.isEmpty && cleared.checkpoints.isEmpty && cleared.recordingEnabled && FileManager.default.fileExists(atPath: unrelated.path), "Clear preserves the preference and unrelated files")

        print("BrowsingHistoryChecks: \(checks) regression assertions passed")
    }
}
