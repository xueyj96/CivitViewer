import Foundation

@main struct LocalDiagnosticsChecks {
    static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1; precondition(condition(), message)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalDiagnosticsChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("owned", isDirectory: true), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("owned/diagnostics-0.jsonl")
        let adjacent = root.appendingPathComponent("owned/unrelated.fixture")
        try Data("keep".utf8).write(to: adjacent)
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = LocalDiagnosticsStore(fileURL: file, build: 123, now: { clock.date })

        await store.record(area: .search, code: .network, httpStatus: 999, count: -9)
        var entries = try await store.entries()
        check(entries.count == 1 && entries[0].httpStatus == nil && entries[0].count == 0 && entries[0].build == 123, "Typed whitelist records clamp invalid numeric inputs")
        await store.record(area: .search, code: .network, httpStatus: nil, count: 3)
        clock.date.addTimeInterval(11)
        await store.record(area: .search, code: .network, httpStatus: nil, count: 4)
        entries = try await store.entries()
        check(entries.count == 2 && entries[0].suppressed == 1, "Per-event rate limiting aggregates suppressed events into the next accepted record")

        let exported = try await store.exportData()
        let exportText = String(decoding: exported, as: UTF8.self)
        check(!exportText.contains("://") && !exportText.lowercased().contains("token") && !exportText.contains("message"), "Export contains only typed fields and no URL, token or free-form message")
        let exportDecoder = JSONDecoder(); exportDecoder.dateDecodingStrategy = .iso8601
        let decoded = try exportDecoder.decode(ExportFixture.self, from: exported)
        check(decoded.schemaVersion == 1 && decoded.entries == entries, "Sanitized JSON export round-trips the retained typed entries")

        let restarted = LocalDiagnosticsStore(fileURL: file, build: 124, now: { clock.date })
        let restartedEntries = try await restarted.entries()
        check(restartedEntries == entries, "Restart reads append-only JSONL entries")
        await restarted.record(area: .lifecycle, code: .appStarted)
        clock.date.addTimeInterval(1)
        await restarted.record(area: .lifecycle, code: .foreground)
        clock.date.addTimeInterval(1)
        await restarted.record(area: .lifecycle, code: .background)
        let lifecycleEntries = try await restarted.entries()
        let lifecycleCodes = lifecycleEntries.filter { $0.area == DiagnosticArea.lifecycle }.map { $0.code }
        check(lifecycleCodes == [.background,.foreground,.appStarted], "Lifecycle events persist newest-first without extra payload fields")

        // Global limit: 31 different status keys in one minute accepts 30, then carries suppression.
        let rateFile = root.appendingPathComponent("rate/diagnostics-0.jsonl")
        let rateStore = LocalDiagnosticsStore(fileURL: rateFile, build: 1, now: { clock.date })
        for status in 100...130 { await rateStore.record(area: .cache, code: .http, httpStatus: status) }
        var rateEntries = try await rateStore.entries()
        check(rateEntries.count == 30, "Global limiter caps writes at 30 per minute")
        clock.date.addTimeInterval(61)
        await rateStore.record(area: .cache, code: .http, httpStatus: 131)
        rateEntries = try await rateStore.entries()
        check(rateEntries.count == 31 && rateEntries[0].suppressed == 1, "Global dropped-event count is carried into the next writable record")

        // Rotation remains bounded by four 256 KiB / 250-event segments and 1,000 entries.
        let boundedFile = root.appendingPathComponent("bounded/diagnostics-0.jsonl")
        let bulkClock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let boundedStore = LocalDiagnosticsStore(fileURL: boundedFile, build: 2, now: { bulkClock.date })
        for index in 0..<1_080 {
            if index > 0 && index % 30 == 0 { bulkClock.date.addTimeInterval(61) }
            await boundedStore.record(area: DiagnosticArea.allCases[index % DiagnosticArea.allCases.count],
                                      code: DiagnosticCode.allCases[index % DiagnosticCode.allCases.count],
                                      httpStatus: 100 + (index % 500), count: index)
        }
        let boundedEntries = try await boundedStore.entries()
        let segmentURLs = (0..<4).map { boundedFile.deletingLastPathComponent().appendingPathComponent("diagnostics-\($0).jsonl") }
        let byteTotal = segmentURLs.compactMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber }.reduce(0) { $0 + $1.intValue }
        check(boundedEntries.count <= 1_000 && byteTotal <= 1_048_576 && segmentURLs.filter { FileManager.default.fileExists(atPath: $0.path) }.count <= 4, "Rotation bounds retained events to 1,000 and disk to 1 MiB")

        // Seven-day expiry compacts old data; malformed tail is skipped without losing the valid prefix.
        bulkClock.date.addTimeInterval(8 * 24 * 60 * 60)
        let expiredBeforeNewRecord = try await boundedStore.entries()
        check(expiredBeforeNewRecord.isEmpty, "Seven-day retention expires old events on read")
        await boundedStore.record(area: .lifecycle, code: .foreground)
        let retainedAfterExpiry = try await boundedStore.entries()
        check(retainedAfterExpiry.count == 1, "New event remains after expired records are compacted")
        let corruptURL = root.appendingPathComponent("corrupt/diagnostics-0.jsonl")
        let corruptStore = LocalDiagnosticsStore(fileURL: corruptURL, build: 3, now: { clock.date })
        await corruptStore.record(area: .cache, code: .storage)
        var bytes = try Data(contentsOf: corruptURL); bytes.append(Data("{truncated".utf8)); try bytes.write(to: corruptURL)
        let recovered = LocalDiagnosticsStore(fileURL: corruptURL, build: 3, now: { clock.date })
        let recoveredEntries = try await recovered.entries()
        check(recoveredEntries.count == 1, "Valid JSONL prefix remains readable when the final tail is truncated")

        let oversizedDirectory = root.appendingPathComponent("oversized", isDirectory: true)
        try FileManager.default.createDirectory(at: oversizedDirectory, withIntermediateDirectories: true)
        let oversizedURL = oversizedDirectory.appendingPathComponent("diagnostics-0.jsonl")
        let oversizedAdjacent = oversizedDirectory.appendingPathComponent("neighbor.fixture")
        try Data("neighbor".utf8).write(to: oversizedAdjacent)
        let oversizedWriter = LocalDiagnosticsStore(fileURL: oversizedURL, build: 4, now: { clock.date })
        await oversizedWriter.record(area: .restore, code: .loadFailed)
        let validPrefix = try Data(contentsOf: oversizedURL)
        var oversizedBytes = validPrefix
        oversizedBytes.append(Data(repeating: 0x78, count: 2_000_000))
        try oversizedBytes.write(to: oversizedURL)
        let oversizedReader = LocalDiagnosticsStore(fileURL: oversizedURL, build: 4, now: { clock.date })
        let salvaged = try await oversizedReader.entries()
        let repairedSize = try FileManager.default.attributesOfItem(atPath: oversizedURL.path)[.size] as! NSNumber
        let neighborValue = String(decoding: try Data(contentsOf: oversizedAdjacent), as: UTF8.self)
        check(salvaged.count == 1 && repairedSize.intValue < 256 * 1024 && neighborValue == "neighbor", "Oversized segment read is capped, valid prefix is salvaged, and only owned log files are compacted")

        try await restarted.clear()
        let afterClear = try await restarted.entries()
        let adjacentValue = String(decoding: try Data(contentsOf: adjacent), as: UTF8.self)
        check(afterClear.isEmpty && adjacentValue == "keep", "Clear removes only owned diagnostic segments")

        let focusedFile = root.appendingPathComponent("focused/diagnostics-0.jsonl")
        let focused = LocalDiagnosticsStore(fileURL: focusedFile, build: 43, now: { clock.date })
        let fixture = root.appendingPathComponent("local-source.mp4")
        try Data(repeating: 1, count: 1_024).write(to: fixture)
        let privateSentinel = "qa-private-sentinel"
        let requested = URL(string: "https://example.invalid/video.webm?signature=\(privateSentinel)")!
        let underlying = NSError(domain: "NSOSStatusErrorDomain", code: -12848,
                                 userInfo: [NSLocalizedDescriptionKey: privateSentinel])
        let native = NSError(domain: "AVFoundationErrorDomain", code: -11829,
                             userInfo: [NSUnderlyingErrorKey: underlying, NSLocalizedDescriptionKey: privateSentinel])
        let first = PlaybackFailureDiagnostic(workID: 146_853_866, source: .cache, requestedURL: requested,
            sourceURL: fixture, recoveryAttempted: false, error: native, eventStatusCodes: [0, -12848, 403])!
        let retry = PlaybackFailureDiagnostic(workID: 146_853_866, source: .network, requestedURL: requested,
            sourceURL: requested, recoveryAttempted: true, error: native, eventStatusCodes: [403])!
        check(first.nativeErrors.map(\.code) == [-11829, -12848] && first.source == .cache && first.localBytes == 1_024,
              "Targeted diagnostic retains actual native chain and local source metadata")
        check(first.requestedExtension == .webm && first.sourceExtension == .mp4 && first.eventStatusCodes == [-12848, 403],
              "Requested and actual suffix hints remain distinct; native status codes stay numeric")
        check(PlaybackFailureDiagnostic(workID: 7, source: .network, requestedURL: requested, sourceURL: requested,
              recoveryAttempted: false, error: native, eventStatusCodes: []) == nil,
              "Other work IDs never opt into targeted diagnostic capture")
        let currentTarget = PlaybackFailureDiagnostic(workID: 146_853_737, source: .network, requestedURL: requested,
            sourceURL: requested, recoveryAttempted: false, error: native, eventStatusCodes: [403])!
        check(currentTarget.workID == 146_853_737 && currentTarget.isBounded && currentTarget.nativeErrors.map(\.code) == [-11829, -12848],
              "The newly human-confirmed work retains its own ID and native chain")
        check(PlaybackFailureDiagnostic(workID: 146_853_738, source: .network, requestedURL: requested, sourceURL: requested,
              recoveryAttempted: false, error: native, eventStatusCodes: []) == nil,
              "An adjacent undesignated work stays outside diagnostic capture")
        let currentFile = root.appendingPathComponent("current-target/diagnostics-0.jsonl")
        let currentStore = LocalDiagnosticsStore(fileURL: currentFile, build: 46, now: { clock.date })
        await currentStore.record(area: .playback, code: .playbackFailed, playback: currentTarget)
        let currentRestart = LocalDiagnosticsStore(fileURL: currentFile, build: 46, now: { clock.date })
        let currentRecords = try await currentRestart.entries()
        check(currentRecords.count == 1 && currentRecords[0].playback == currentTarget,
              "The new designated work survives persisted-log validation and restart")
        let posterContext = PlaybackFailureDiagnostic(workID: 146_087_479, source: .network,
            requestedURL: requested, sourceURL: requested, recoveryAttempted: false,
            error: native, eventStatusCodes: [])!
        let posterFile = root.appendingPathComponent("poster/diagnostics-0.jsonl")
        let posterStore = LocalDiagnosticsStore(fileURL: posterFile, build: 48, now: { clock.date })
        await posterStore.record(area: .thumbnail, code: .posterFailed, playback: posterContext)
        await posterStore.record(area: .thumbnail, code: .posterLoaded, playback: posterContext)
        await posterStore.record(area: .thumbnail, code: .decode, playback: posterContext)
        await posterStore.record(area: .search, code: .posterFailed, playback: posterContext)
        let posterRestart = LocalDiagnosticsStore(fileURL: posterFile, build: 48, now: { clock.date })
        let posterEntries = try await posterRestart.entries()
        check(posterEntries.filter { $0.area == .thumbnail && [.posterFailed, .posterLoaded].contains($0.code) }.allSatisfy { $0.playback == posterContext },
              "Both poster event types retain the designated work ID and typed errors after persistence and restart")
        check(posterEntries.count == 4 && posterEntries.filter { $0.code == .decode || $0.area == .search }.allSatisfy { $0.playback == nil },
              "Unrelated thumbnail codes and other areas cannot gain targeted payloads")
        check(PlaybackFailureDiagnostic(workID: 146_087_480, source: .network, requestedURL: requested,
            sourceURL: requested, recoveryAttempted: false, error: native, eventStatusCodes: []) == nil,
              "The adjacent undesignated poster work is excluded")
        let posterExport = String(decoding: try await posterRestart.exportData(), as: UTF8.self)
        check(!posterExport.contains(privateSentinel) && !posterExport.contains("://") && !posterExport.contains("example.invalid"),
              "Poster exports contain no URLs or native error descriptions")
        let stagedPoster = PlaybackFailureDiagnostic(workID: 146_087_479, source: .network, requestedURL: requested,
            sourceURL: requested, recoveryAttempted: false, error: native, eventStatusCodes: [],
            posterStage: .declaredImage, posterFailure: .decode)!
        let capturedPoster = PlaybackFailureDiagnostic(workID: 146_087_479, source: .local, requestedURL: requested,
            sourceURL: fixture, recoveryAttempted: true, error: nil, eventStatusCodes: [], posterStage: .decodedFrame)!
        let stageFile = root.appendingPathComponent("poster-stage/diagnostics-0.jsonl")
        let stagedStore = LocalDiagnosticsStore(fileURL: stageFile, build: 49, now: { clock.date })
        await stagedStore.record(area: .thumbnail, code: .posterFailed, playback: stagedPoster)
        await stagedStore.record(area: .thumbnail, code: .posterCaptured, playback: capturedPoster)
        let stagedRestart = LocalDiagnosticsStore(fileURL: stageFile, build: 49, now: { clock.date })
        let stages = try await stagedRestart.entries()
        check(stages.count == 2 && stages.contains { $0.playback?.posterStage == .declaredImage && $0.playback?.posterFailure == .decode },
              "Failure stage and typed kind survive persisted restart")
        check(stages.contains { $0.code == .posterCaptured && $0.playback == capturedPoster }, "A successful current-frame capture has a separate allowlisted event")
        let unavailableRoute = PlaybackFailureDiagnostic(workID: 146_087_479, posterRoute: .detailsUnavailable,
            sourceURL: nil, declaredURL: nil)!
        check(unavailableRoute.source == .unavailable && unavailableRoute.requestedExtension == .other &&
              unavailableRoute.engine == nil && unavailableRoute.isBounded, "A rejected route is represented as unavailable without a fabricated URL or decoder")
        check(PlaybackFailureDiagnostic(workID: 146_087_480, posterRoute: .detailsVideo,
            sourceURL: requested, declaredURL: requested) == nil, "Route observations retain the same three-ID allowlist")
        check(PlaybackFailureDiagnostic(workID: 146_087_479, posterRoute: .decodedFrame,
            sourceURL: requested, declaredURL: nil) == nil, "Route construction accepts only the finite route stages")
        let routeFile = root.appendingPathComponent("poster-route/diagnostics-0.jsonl")
        let routeStore = LocalDiagnosticsStore(fileURL: routeFile, build: 50, now: { clock.date })
        await routeStore.record(area: .thumbnail, code: .posterOpened, playback: unavailableRoute)
        for code: DiagnosticCode in [.posterStarted, .posterCancelled, .posterCaptureStarted, .posterDeferred] {
            await routeStore.record(area: .thumbnail, code: code, playback: stagedPoster)
        }
        let routeRestart = LocalDiagnosticsStore(fileURL: routeFile, build: 50, now: { clock.date })
        let routeEntries = try await routeRestart.entries()
        check(routeEntries.count == 5 && routeEntries.first?.playback == unavailableRoute &&
              routeEntries.dropFirst().allSatisfy { $0.playback == stagedPoster }, "Entry, request, cancellation and deferred/capture markers retain context through persisted restart")
        let routeText = String(decoding: try await routeRestart.exportData(), as: UTF8.self)
        check(!routeText.contains(privateSentinel) && !routeText.contains("://") && !routeText.contains("example.invalid"), "Route markers introduce no request URLs or free-form errors")
        await focused.record(area: .playback, code: .playbackFailed, playback: first)
        await focused.record(area: .playback, code: .playbackFailed, playback: first)
        await focused.record(area: .playback, code: .playbackFailed, playback: retry)
        let focusedEntries = try await focused.entries()
        check(focusedEntries.count == 2 && Set(focusedEntries.compactMap { $0.playback?.attempt }) == [0, 1],
              "Initial and retry failures retain distinct context inside the ordinary debounce window")
        check(focusedEntries.contains { $0.suppressed == 1 }, "Exact duplicate target failures retain the existing suppression contract")
        let focusedExport = try await focused.exportData()
        let focusedText = String(decoding: focusedExport, as: UTF8.self)
        check(!focusedText.contains(privateSentinel) && !focusedText.contains("://") && !focusedText.contains("example.invalid") && !focusedText.contains("local-source"),
              "Export never contains source URLs, paths, query values or native free-form descriptions")
        let focusedRestart = LocalDiagnosticsStore(fileURL: focusedFile, build: 44, now: { clock.date })
        let focusedAfterRestart = try await focusedRestart.entries()
        check(focusedAfterRestart == focusedEntries, "New optional context survives restart alongside compatible old entries")
        let unknownDomain = NSError(domain: privateSentinel, code: Int.max)
        let safeUnknown = PlaybackFailureDiagnostic(workID: 146_853_866, source: .offline, requestedURL: requested,
            sourceURL: fixture, recoveryAttempted: false, error: unknownDomain, eventStatusCodes: [Int.min, Int.max])!
        check(safeUnknown.nativeErrors.first?.domain == .other && safeUnknown.nativeErrors.first?.code == Int(Int32.max) && safeUnknown.isBounded,
              "Unknown native domains are reduced to an enum; integer codes are bounded")
        var longError = native
        for _ in 0..<10 { longError = NSError(domain: "AVFoundationErrorDomain", code: -11829, userInfo: [NSUnderlyingErrorKey: longError]) }
        let maximum = PlaybackFailureDiagnostic(workID: 146_853_866, source: .cache, requestedURL: requested,
            sourceURL: fixture, recoveryAttempted: true, error: longError, eventStatusCodes: Array(1...20))!
        check(maximum.nativeErrors.count == 5 && maximum.eventStatusCodes.count == 4, "Native chains and error-log codes have fixed capture bounds")
        let ebml = root.appendingPathComponent("misnamed.mp4")
        try Data([0x1a, 0x45, 0xdf, 0xa3, 0, 0]).write(to: ebml)
        let repairContext = PlaybackFailureDiagnostic(workID: 146_853_866, source: .offline,
            requestedURL: requested, sourceURL: ebml, recoveryAttempted: true, error: nil,
            eventStatusCodes: [], repairMode: .remux, videoCodec: .vp9)!
        check(repairContext.containerHint == .ebml && repairContext.sourceExtension == .mp4 && repairContext.videoCodec == .vp9,
              "Container bytes and declared suffix stay distinct in repair evidence")
        let newData = try JSONEncoder().encode(repairContext)
        var legacy = try JSONSerialization.jsonObject(with: newData) as! [String: Any]
        for key in ["engine", "containerHint", "repairMode", "videoCodec"] { legacy[key] = nil }
        let legacyDecoded = try JSONDecoder().decode(PlaybackFailureDiagnostic.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(legacyDecoded.engine == nil && legacyDecoded.repairMode == nil && legacyDecoded.workID == 146_853_866,
              "Old diagnostic payload remains readable with all new optional fields absent")
        let repairStore = LocalDiagnosticsStore(fileURL: root.appendingPathComponent("repair/diagnostics-0.jsonl"), build: 47, now: { clock.date })
        await repairStore.record(area: .playback, code: .repairCompleted, playback: repairContext)
        let repairRecords = try await repairStore.entries()
        check(repairRecords.count == 1 && repairRecords.first?.playback == repairContext,
              "Repair enum metadata persists inside the same bounded privacy contract")
        let payloadClock = TestClock(clock.date)
        let payloadFile = root.appendingPathComponent("payload-cap/diagnostics-0.jsonl")
        let payloadStore = LocalDiagnosticsStore(fileURL: payloadFile, build: 43, now: { payloadClock.date })
        for _ in 0..<1_080 {
            await payloadStore.record(area: .playback, code: .playbackFailed, playback: maximum)
            payloadClock.date.addTimeInterval(11)
        }
        let payloadEntries = try await payloadStore.entries()
        let payloadExport = try await payloadStore.exportData()
        let payloadSegments = (0..<4).map { payloadFile.deletingLastPathComponent().appendingPathComponent("diagnostics-\($0).jsonl") }
        let payloadBytes = payloadSegments.compactMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber }.reduce(0) { $0 + $1.intValue }
        check(payloadEntries.count <= 1_000 && payloadBytes <= 1_048_576 && payloadExport.count <= 1_100_000,
              "Representative maximum-context traffic preserves disk, event and export caps")
        print("LocalDiagnosticsChecks: \(checks) local assertions passed; bulk sample \(boundedEntries.count) retained events / \(byteTotal) bytes")
    }
}

private struct ExportFixture: Decodable { let schemaVersion: Int; let entries: [DiagnosticEntry] }
private final class TestClock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}
