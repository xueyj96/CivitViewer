import Foundation
import Combine
import AVFoundation

@MainActor
@main struct ContinuousPrefetchChecks {
    static func main() async throws {
        guard CommandLine.arguments.count == 3, let base = URL(string: CommandLine.arguments[1]) else {
            fatalError("usage: continuous-prefetch-checks BASE_URL FIXTURE_MP4")
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("continuous59-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[2])
        precondition(FileManager.default.fileExists(atPath: fixture.path), "The legal silent MP4 fixture must be present beside the probe executable")

        func item(_ id: Int, _ path: String) -> MediaItem {
            MediaItem(id: id, url: base.appendingPathComponent(path).absoluteString, width: nil, height: nil,
                type: "video", username: nil, browsingLevel: 1, thumbnail: nil)
        }
        func imageItem(_ id: Int, _ url: URL) -> MediaItem {
            MediaItem(id: id, url: url.absoluteString, width: nil, height: nil,
                type: "image", username: nil, browsingLevel: 1, thumbnail: nil)
        }
        func stats() async throws -> [String: Any] {
            let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        func reset(_ caseName: String) async throws {
            _ = try await URLSession.shared.data(from: URL(string: base.absoluteString + "/reset?case=" + caseName)!)
        }
        func mark(_ name: String) async throws {
            _ = try await URLSession.shared.data(from: URL(string: base.absoluteString + "/mark?name=" + name)!)
        }
        func releaseImageGate() async throws {
            _ = try await URLSession.shared.data(from: base.appendingPathComponent("release-image-gate"))
        }
        func waitUntil(_ timeout: Double = 8, _ predicate: @MainActor () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                if predicate() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return predicate()
        }
        func waitServer(_ timeout: Double = 8, _ predicate: ([String: Any]) -> Bool) async -> [String: Any]? {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                if let value = try? await stats(), predicate(value) { return value }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return try? await stats()
        }
        func inFlightConsumerCounts(_ cache: MediaCache) -> [Int] {
            guard let flights = Mirror(reflecting: cache).children.first(where: { $0.label == "inFlight" })?.value else { return [] }
            return Mirror(reflecting: flights).children.compactMap { entry in
                let tuple = Mirror(reflecting: entry.value).children
                guard let value = tuple.first(where: { $0.label == "value" })?.value,
                      let consumers = Mirror(reflecting: value).children.first(where: { $0.label == "consumers" })?.value as? Set<UUID> else { return nil }
                return consumers.count
            }
        }

        let defaults = UserDefaults.standard
        let prior = defaults.object(forKey: "wifiVideoPrefetch")
        defaults.set(false, forKey: "wifiVideoPrefetch")
        defer { if let prior { defaults.set(prior, forKey: "wifiVideoPrefetch") } else { defaults.removeObject(forKey: "wifiVideoPrefetch") } }
        var windowRows: [[String: Any]] = []
        var playbackRows: [[String: Any]] = []
        var imageHandoff: [String: Any] = [:]
        var playbackLimits: [String] = []

        for round in 0..<3 {
            try await reset("window\(round)")
            let dir = scratch.appendingPathComponent("window-\(round)")
            let cache = MediaCache(directoryURL: dir, monitorNetwork: false, diagnostics: nil, availableBytesProvider: { 2_000_000_000 })
            let controller = MediaPreloader(cache: cache, network: Just(true).eraseToAnyPublisher())
            let items = (0..<12).map { item(round * 100 + $0, "w\(round)-\($0).mp4") }
            controller.update(items, after: 3, count: 6, context: "window-\(round)", wifiOnly: false)
            let gated = await waitServer { value in
                let paths = (value["requests"] as? [String: Any] ?? [:]).keys
                return paths.contains("/w\(round)-4.mp4") && paths.contains("/w\(round)-5.mp4")
            }
            precondition(gated != nil, "The two distant initial jobs must both reach the local gate before reversing direction")
            try await mark("reverse-\(round)")
            controller.update(items, after: 1, count: 6, context: "window-\(round)", wifiOnly: false)
            let reverseSnapshot = controller.snapshot
            let pendingBudgetAfterReverseUpdate = cache.pendingDownloadBudget
            let nearReady = await waitUntil(8) {
                cache.cached(items[2].mediaURL!, video: true) != nil && cache.cached(items[3].mediaURL!, video: true) != nil
            }
            let nearSnapshot = controller.snapshot
            let pendingBudgetAfterNearReady = cache.pendingDownloadBudget
            let requestSnapshot = await waitServer { value in
                let paths = value["requests"] as? [String: Any] ?? [:]
                return paths["/w\(round)-2.mp4"] != nil && paths["/w\(round)-3.mp4"] != nil
            }
            let currentStats = try await stats()
            let reqs = currentStats["requests"] as? [String: Any] ?? [:]
            let events = currentStats["events"] as? [[String: Any]] ?? []
            let relevant = events.filter { (($0["path"] as? String) ?? "").hasPrefix("/w\(round)-") }
            let nearStarts = relevant.filter { ["/w\(round)-2.mp4", "/w\(round)-3.mp4"].contains($0["path"] as? String ?? "") }
            let nearTimes = nearStarts.compactMap { $0["startMs"] as? Int }
            let reverseMs = currentStats["marks"] as? [String: Int] ?? [:]
            let reverseAt = reverseMs["reverse-\(round)"] ?? 0
            let canceled = relevant.filter { $0["aborted"] as? Bool == true }.compactMap { $0["path"] as? String }
            let peak = (currentStats["maxActive"] as? Int) ?? 0
            controller.stop()
            _ = await waitUntil(2) { cache.pendingDownloadBudget == 0 }
            let remaining = cache.pendingDownloadBudget
            precondition(nearReady, "Both newly-near videos must become fully cached")
            precondition(remaining == 0, "All completed/canceled preload reservations must be released")
            windowRows.append([
                "round": round + 1, "nearFirstRequestMsFromServerReset": nearTimes.min() as Any? ?? NSNull(),
                "nearFirstRequestMsFromReverse": nearTimes.min().map { max(0, $0 - reverseAt) } as Any? ?? NSNull(),
                "nearTargetRequestCount": nearStarts.count, "nearTargetsCached": nearReady,
                "snapshotAfterReverseUpdate": ["active": reverseSnapshot.active, "desired": reverseSnapshot.desired, "ready": reverseSnapshot.ready],
                "pendingDownloadBudgetAfterReverseUpdate": pendingBudgetAfterReverseUpdate,
                "snapshotWhenNearReady": ["active": nearSnapshot.active, "desired": nearSnapshot.desired, "ready": nearSnapshot.ready],
                "pendingDownloadBudgetWhenNearReady": pendingBudgetAfterNearReady,
                "gatedFarAbortedPaths": canceled, "maxActive": peak,
                "finalPendingDownloadBudget": remaining, "requestCountPaths": reqs.count,
                "events": relevant
            ])
            _ = requestSnapshot
        }

        try await reset("image-handoff")
        let imageCache = MediaCache(directoryURL: scratch.appendingPathComponent("image-handoff"), monitorNetwork: false,
            diagnostics: nil, availableBytesProvider: { 2_000_000_000 })
        let imageController = MediaPreloader(cache: imageCache, network: Just(true).eraseToAnyPublisher())
        let imageURL = base.appendingPathComponent("handoff-image.png")
        let imageItems = [item(5000, "handoff-current.mp4"), imageItem(5001, imageURL)]
        imageController.update(imageItems, after: 0, count: 3, context: "image-handoff", wifiOnly: false)
        let imageStarted = await waitServer { value in
            (value["requests"] as? [String: Any] ?? [:])["/handoff-image.png"] != nil
        }
        precondition(imageStarted != nil, "Image preload must reach its local gate before the target becomes current")
        imageController.update(imageItems, after: 1, count: 3, context: "image-handoff", wifiOnly: false)
        let snapshotAfterCurrent = imageController.snapshot
        let pendingAtCurrent = imageCache.pendingDownloadBudget
        var controlRetiredOldFlight: Bool? = nil
        var controlSawCanceledWriter: Bool? = nil
        #if LEGACY_CANCEL_CURRENT_IMAGE59
        controlRetiredOldFlight = await waitUntil(2) {
            imageController.snapshot.active == 0 && inFlightConsumerCounts(imageCache).isEmpty
        }
        let canceledWriterStats = await waitServer(2) { value in
            let events = value["events"] as? [[String: Any]] ?? []
            return events.contains { $0["path"] as? String == "/handoff-image.png" && $0["aborted"] as? Bool == true }
        }
        controlSawCanceledWriter = canceledWriterStats != nil
        #endif
        let foregroundImage = Task { @MainActor in await imageCache.image(imageURL) }
        await Task.yield()
        let joined = await waitUntil(1.5) { inFlightConsumerCounts(imageCache).contains(2) }
        let consumersAtGate = inFlightConsumerCounts(imageCache)
        try await releaseImageGate()
        let foregroundImageValue = await foregroundImage.value
        let cachedImage = await waitUntil(3) { imageCache.cached(imageURL, video: false) != nil }
        imageController.stop()
        _ = await waitUntil(3) { imageCache.pendingDownloadBudget == 0 }
        let imageBudgetAfter = imageCache.pendingDownloadBudget
        let imageStats = await waitServer { value in
            let events = value["events"] as? [[String: Any]] ?? []
            let requests = events.filter { $0["path"] as? String == "/handoff-image.png" }
            return !requests.isEmpty && requests.allSatisfy { $0["endMs"] is Int }
        }
        let imageEvents = (imageStats?["events"] as? [[String: Any]] ?? []).filter { $0["path"] as? String == "/handoff-image.png" }
        let singleWriter = imageEvents.count == 1
        let foregroundImageSucceeded = foregroundImageValue != nil
        let imagePassed = joined && singleWriter && foregroundImageSucceeded && cachedImage && imageBudgetAfter == 0
        imageHandoff = [
            "preloadStartedBeforeCurrent": true,
            "legacyCancelControl": ProcessInfo.processInfo.environment["CONTINUOUS59_CONTROL"] == "cancel-current-image",
            "controlRetiredOldFlightBeforeForegroundJoin": controlRetiredOldFlight as Any? ?? NSNull(),
            "controlSawCanceledWriterBeforeForegroundJoin": controlSawCanceledWriter as Any? ?? NSNull(),
            "snapshotAfterCurrent": ["active": snapshotAfterCurrent.active, "desired": snapshotAfterCurrent.desired, "ready": snapshotAfterCurrent.ready],
            "pendingDownloadBudgetAtCurrent": pendingAtCurrent,
            "flightConsumerCountsBeforeGateRelease": consumersAtGate,
            "sameFlightJoined": joined,
            "httpWriterCount": imageEvents.count,
            "singleHttpWriter": singleWriter,
            "foregroundImageSucceeded": foregroundImageSucceeded,
            "sharedResultCached": cachedImage,
            "pendingDownloadBudgetAfter": imageBudgetAfter,
            "events": imageEvents,
            "assertionsPassed": imagePassed
        ]
        #if !BASELINE_CONTINUOUS59
        precondition(imagePassed, "Current image handoff must join the gated preload flight once and release its budget")
        #endif

        for round in 0..<3 {
            try await reset("play\(round)")
            let dir = scratch.appendingPathComponent("play-\(round)")
            let cache = MediaCache(directoryURL: dir, monitorNetwork: false, diagnostics: nil, availableBytesProvider: { 2_000_000_000 })
            let controller = MediaPreloader(cache: cache, network: Just(true).eraseToAnyPublisher())
            let playURL = base.appendingPathComponent("play-\(round).mp4")
            let one = MediaItem(id: round + 1000, url: playURL.absoluteString, width: nil, height: nil,
                type: "video", username: nil, browsingLevel: 1, thumbnail: nil)
            controller.update([item(round + 2000, "unused-current"), one], after: 0, count: 3, context: "play-\(round)", wifiOnly: false)
            let backgroundStarted = await waitServer { value in (value["requests"] as? [String: Any] ?? [:])["/play-\(round).mp4"] != nil }
            precondition(backgroundStarted != nil, "Actual MediaPreloader/MediaCache preloading must start before making the URL foreground demand")

            let demandOwner = UUID()
            try await mark("demand-\(round)")
            #if !BASELINE_CONTINUOUS59
            cache.setForegroundVideoDemand(url: playURL, owner: demandOwner, waiting: true)
            #endif
            let item = AVPlayerItem(url: playURL)
            item.preferredForwardBufferDuration = 1
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            player.automaticallyWaitsToMinimizeStalling = false
            let readyAt = Date()
            player.play()
            let statusObservation = item.observe(\.status, options: [.initial, .new]) { _, _ in }
            _ = statusObservation
            let becameReady = await waitUntil(8) { item.status == .readyToPlay }
            let readyMs = becameReady ? Int(Date().timeIntervalSince(readyAt) * 1000) : nil
            let startedSeconds = player.currentTime().seconds
            let advanced = await waitUntil(5) {
                let now = player.currentTime().seconds
                return now.isFinite && startedSeconds.isFinite && now > startedSeconds + 0.15
            }
            let advancedSeconds = player.currentTime().seconds
            player.pause(); player.replaceCurrentItem(with: nil)
            #if !BASELINE_CONTINUOUS59
            cache.removeForegroundVideoDemand(owner: demandOwner)
            #endif
            controller.stop()
            _ = await waitUntil(2) { cache.pendingDownloadBudget == 0 }
            let playbackStats = try await stats()
            let events = playbackStats["events"] as? [[String: Any]] ?? []
            let relevant = events.filter { $0["path"] as? String == "/play-\(round).mp4" }
            let canceled = relevant.filter { $0["aborted"] as? Bool == true }
            let backgroundCanceled = canceled.filter { $0["range"] == nil || $0["range"] is NSNull }
            let playerCanceled = canceled.filter { $0["range"] != nil && !($0["range"] is NSNull) }
            let marks = playbackStats["marks"] as? [String: Int] ?? [:]
            let demandMs = marks["demand-\(round)"] ?? 0
            let cancelLatencies = canceled.compactMap { event -> Int? in
                guard let end = event["endMs"] as? Int, end >= demandMs else { return nil }
                return end - demandMs
            }
            let backgroundCancelLatencies = backgroundCanceled.compactMap { event -> Int? in
                guard let end = event["endMs"] as? Int, end >= demandMs else { return nil }
                return end - demandMs
            }
            var overlaps: [[String: Any]] = []
            for left in relevant.indices {
                for right in relevant.indices where right > left {
                    guard let a0 = relevant[left]["firstByteMs"] as? Int, let a1 = relevant[left]["lastByteMs"] as? Int,
                          let b0 = relevant[right]["firstByteMs"] as? Int, let b1 = relevant[right]["lastByteMs"] as? Int else { continue }
                    let overlap = max(0, min(a1, b1) - max(a0, b0))
                    if overlap > 0 { overlaps.append(["requestA": left, "requestB": right, "overlapMs": overlap]) }
                }
            }
            if !becameReady { playbackLimits.append("AVPlayerItem did not reach readyToPlay within 8s (round \(round + 1))") }
            if !advanced { playbackLimits.append("AVPlayer time did not advance within 5s in headless macOS process (round \(round + 1))") }
            playbackRows.append([
                "round": round + 1, "itemReady": becameReady, "itemReadyMs": readyMs as Any? ?? NSNull(),
                "playbackAdvanced": advanced, "startedSeconds": startedSeconds.isFinite ? startedSeconds : NSNull(),
                "advancedSeconds": advancedSeconds.isFinite ? advancedSeconds : NSNull(),
                "transportRequestCount": relevant.count,
                "transport": relevant, "abortedRequests": canceled.count,
                "abortedBackgroundGETs": backgroundCanceled.count, "abortedAVPlayerRanges": playerCanceled.count,
                "allAbortToServerClosureMs": cancelLatencies, "backgroundAbortToServerClosureMs": backgroundCancelLatencies,
                "overlapPairs": overlaps,
                "maxActive": playbackStats["maxActive"] as? Int ?? 0,
                "finalPendingDownloadBudget": cache.pendingDownloadBudget,
                "silenced": player.isMuted
            ])
        }
        let report: [String: Any] = [
            "baselineBuild": ProcessInfo.processInfo.environment["CONTINUOUS59_BASELINE"] == "1",
            "windowScheduler": windowRows, "imageHandoff": imageHandoff, "foregroundPlayback": playbackRows,
            "playbackMeasurementLimitations": playbackLimits,
            "playbackFixture": ["path": fixture.path, "bytes": ((try? fixture.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil) as Any? ?? NSNull(), "localOnly": true, "silent": true]
        ]
        let output = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("CONTINUOUS59_JSON=" + String(decoding: output, as: UTF8.self))
    }
}
