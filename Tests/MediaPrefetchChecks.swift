import Foundation
import Combine

@main struct MediaPrefetchChecks {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count >= 3 else { fatalError("usage: checks BASE_URL MODE") }
        let base = URL(string: CommandLine.arguments[1])!
        let legacy = CommandLine.arguments[2] == "--baseline51"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-prefetch-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MediaCache(directoryURL: root, monitorNetwork: false, diagnostics: nil, availableBytesProvider: { 2_000_000_000 })
        let defaults = UserDefaults.standard
        let prior = defaults.object(forKey: "wifiVideoPrefetch")
        defaults.set(false, forKey: "wifiVideoPrefetch")
        defer { if let prior { defaults.set(prior, forKey: "wifiVideoPrefetch") } else { defaults.removeObject(forKey: "wifiVideoPrefetch") } }

        func item(_ id: Int, _ path: String, video: Bool = false, poster: String? = nil) -> MediaItem {
            MediaItem(id: id, url: base.appendingPathComponent(path).absoluteString, width: nil, height: nil,
                type: video ? "video" : "image", username: nil, browsingLevel: 1,
                thumbnail: poster.map { .init(url: base.appendingPathComponent($0).absoluteString) })
        }
        let items = [item(0, "current"), item(1, "video1", video: true, poster: "poster1"),
                     item(2, "video2", video: true, poster: "poster2"), item(3, "image3")]
        func stats() async throws -> [String: Any] {
            let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        func resetStats() async throws {
            _ = try await URLSession.shared.data(from: base.appendingPathComponent("reset"))
        }
        func waitForRequest(_ path: String, timeout: Double = 7) async -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                if let requests = try? await stats()["requests"] as? [String: Int], requests[path] != nil { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        func waitForRequestCount(_ path: String, _ expected: Int, timeout: Double = 7) async -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                if let requests = try? await stats()["requests"] as? [String: Int], requests[path, default: 0] >= expected { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        func waitUntil(_ timeout: Double = 7, _ predicate: @MainActor () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
            return predicate()
        }
        func runWindow(_ round: Int) async throws -> [String: Any] {
            let roundItems = [item(round * 10, "r\(round)-current"),
                item(round * 10 + 1, "r\(round)-video1", video: true, poster: "r\(round)-poster1"),
                item(round * 10 + 2, "r\(round)-video2", video: true, poster: "r\(round)-poster2"),
                item(round * 10 + 3, "r\(round)-image3")]
            let started = Date()
            try await resetStats()
            #if LEGACY_PREFETCH51
                let task = Task { await cache.prefetch(roundItems, after: 0) }
                await task.value
            #else
                let controller = MediaPreloader(cache: cache)
                controller.update(roundItems, after: 0, count: 3, context: "round-\(round)", wifiOnly: false)
                let ready = await waitUntil { controller.snapshot.ready >= 5 }
                precondition(ready, "All five window targets must complete")
                precondition(cache.preloadStatus?.ready == 3 && cache.preloadStatus?.total == 3 && cache.preloadStatus?.target == 3,
                             "Visible preload status counts primary works rather than extra poster files")
                controller.stop()
            #endif
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            let serverStats = try await stats()
            let req = serverStats["requests"] as? [String: Any] ?? [:]
            let timing = serverStats["firstRequestMs"] as? [String: Int] ?? [:]
            let paths = ["r\(round)-video1", "r\(round)-video2", "r\(round)-poster1", "r\(round)-poster2", "r\(round)-image3"]
            let completed = paths.filter { path in
                let isVideo = path.contains("video")
                return cache.cached(base.appendingPathComponent(path), video: isVideo) != nil
            }.count
            precondition(completed == 5, "Every comparison round must cache all five expected files; observed \(completed)")
            let videoTimes = [timing["/r\(round)-video1"], timing["/r\(round)-video2"]].compactMap { $0 }
            return ["round": round, "firstVideoRequestMs": videoTimes.min() as Any? ?? NSNull(), "allFiveCompleteMs": completed == 5 ? elapsed : NSNull(), "completedFiles": completed, "expectedFiles": 5]
        }

        var rounds: [[String: Any]] = []
        for index in 1...3 { rounds.append(try await runWindow(index)) }

        var focusVideo2Requests = 0
        #if !LEGACY_PREFETCH51
            let recoveryPath = CurrentValueSubject<Bool, Never>(false)
            let recovery = MediaPreloader(cache: cache, network: recoveryPath.eraseToAnyPublisher())
            let recoveryItems = [item(300, "recover-current"), item(301, "recover-failure-image"), item(302, "recover-paused-video", video: true)]
            recovery.update(recoveryItems, after: 0, count: 3, context: "recover", wifiOnly: true)
            let imageFailed = await waitUntil { recovery.snapshot.failed == 1 }
            precondition(imageFailed, "Recovery begins with an actual failed image request")
            recoveryPath.send(false) // Offline -> cellular can remain non-unmetered.
            let recoveredImage = await waitUntil { cache.cached(recoveryItems[1].mediaURL!, video: false) != nil }
            precondition(recoveredImage, "A new path snapshot retries failed images without another page update")
            let recoveredRequests = try await stats()["requests"] as? [String: Int] ?? [:]
            precondition(recoveredRequests["/recover-failure-image"] == 2 && recoveredRequests["/recover-paused-video"] == nil,
                         "Recovery retries the failed image once while retaining the Wi-Fi video restriction")
            recovery.stop()

            let latePath = CurrentValueSubject<Bool, Never>(false)
            let lateRecovery = MediaPreloader(cache: cache, network: latePath.eraseToAnyPublisher())
            let lateItems = [item(310, "recover-late-current"), item(311, "recover-inflight-image")]
            lateRecovery.update(lateItems, after: 0, count: 3, context: "recover-late", wifiOnly: true)
            let lateStarted = await waitForRequest("/recover-inflight-image")
            precondition(lateStarted, "The old-path request is running before the network changes")
            latePath.send(false)
            let lateReady = await waitUntil { cache.cached(lateItems[1].mediaURL!, video: false) != nil }
            precondition(lateReady, "A late failure from the prior path receives one attempt on the latest path")
            lateRecovery.stop()

            let cancelledOwner = MediaPreloader(cache: cache, network: Just(true).eraseToAnyPublisher())
            let cancelledItems = [item(320, "cancelled-current"), item(321, "cancelled-video", video: true)]
            let staleUpdate = Task { @MainActor in cancelledOwner.update(cancelledItems, after: 0, count: 3, context: "cancelled", wifiOnly: false) }
            staleUpdate.cancel(); await staleUpdate.value
            try? await Task.sleep(for: .milliseconds(100))
            let cancelledRequests = try await stats()["requests"] as? [String: Int] ?? [:]
            precondition(cancelledRequests["/cancelled-video"] == nil && cancelledOwner.snapshot.active == 0,
                         "An already-cancelled view task cannot restart the independent owner")
            cancelledOwner.stop()

            let thin = MediaCache(directoryURL: root.appendingPathComponent("shared-budget"), monitorNetwork: false,
                diagnostics: nil, availableBytesProvider: { 1_000_000_000 + 80 * 1024 * 1024 })
            let budgetA = base.appendingPathComponent("budget-video-a"), budgetB = base.appendingPathComponent("budget-video-b")
            let firstBudget = Task { await thin.fetch(budgetA, video: true) }
            let budgetStarted = await waitForRequest("/budget-video-a")
            precondition(budgetStarted && thin.pendingDownloadBudget == 64 * 1024 * 1024, "The first actual admitted video reserves its bounded budget")
            let sameBudget = Task { await thin.fetch(budgetA, video: true) }
            let secondBudget = Task { await thin.fetch(budgetB, video: true) }
            let refused = await secondBudget.value
            precondition(refused == nil, "Two64MiB flights cannot both consume the same80MiB headroom")
            let firstFile = await firstBudget.value, sameFile = await sameBudget.value
            precondition(firstFile != nil && firstFile == sameFile && thin.pendingDownloadBudget == 0,
                         "A second consumer shares one reservation and the budget is released after completion")
            let budgetRequests = try await stats()["requests"] as? [String: Int] ?? [:]
            precondition(budgetRequests["/budget-video-a"] == 1 && budgetRequests["/budget-video-b"] == nil,
                         "Only the admitted large response is requested")
            let completedBudgetSize = try firstFile!.resourceValues(forKeys: [.fileSizeKey]).fileSize
            precondition(completedBudgetSize == 64 * 1024 * 1024,
                         "The budget case completes a representative64MiB response, not a tiny stand-in")
            let smallBudget = MediaCache(directoryURL: root.appendingPathComponent("small-shared-budget"), monitorNetwork: false,
                diagnostics: nil, availableBytesProvider: { 1_000_000_000 + 80 * 1024 * 1024 })
            let smallOwner = MediaPreloader(cache: smallBudget, network: Just(true).eraseToAnyPublisher())
            let smallItems = [item(330, "space-current"), item(331, "space-small-video1", video: true), item(332, "space-small-video2", video: true)]
            smallOwner.update(smallItems, after: 0, count: 3, context: "small-space", wifiOnly: false)
            let smallFirstReady = await waitUntil { smallBudget.cached(smallItems[1].mediaURL!, video: true) != nil }
            precondition(smallFirstReady, "A constrained owner completes its first admitted target")
            let smallSecondReady = await waitUntil { smallBudget.cached(smallItems[2].mediaURL!, video: true) != nil }
            precondition(smallSecondReady, "After a small file completes, deferred work automatically reuses the released budget without another page gesture")
            smallOwner.stop()
            // Network recovery, stop, context changes, clear, low-space, and duplicate
            // updates are checked through the local server request counts and cache files.
            let subject = CurrentValueSubject<Bool, Never>(false)
            let contractCache = MediaCache(directoryURL: root.appendingPathComponent("contracts"), monitorNetwork: false,
                diagnostics: nil, availableBytesProvider: { 2_000_000_000 })
            let controller = MediaPreloader(cache: contractCache, network: subject.eraseToAnyPublisher())
            let contractItems = [item(80, "c-current"), item(81, "c-video", video: true, poster: "c-poster"), item(82, "c-image")]
            controller.update(contractItems, after: 0, count: 3, context: "wifi", wifiOnly: true)
            let imageReady = await waitUntil { contractCache.cached(contractItems[2].mediaURL!, video: false) != nil }
            precondition(imageReady, "Wi-Fi pause must still allow image prefetch")
            let pausedStats = try await stats()["requests"] as? [String: Int] ?? [:]
            precondition(pausedStats["/c-video"] == nil, "Wi-Fi pause must not request video")
            subject.send(true)
            let videoReady = await waitUntil { contractCache.cached(contractItems[1].mediaURL!, video: true) != nil }
            precondition(videoReady, "Network recovery must resume video without another update")
            controller.stop()
            subject.send(false)
            controller.update(contractItems, after: 0, count: 3, context: "wifi", wifiOnly: true)
            precondition(controller.snapshot.ready == 3, "Wi-Fi restrictions must still reuse all media already cached locally")
            controller.stop()

            let stopped = MediaPreloader(cache: contractCache, network: Just(true).eraseToAnyPublisher())
            let stopItems = [item(90, "s-current"), item(91, "s-video", video: true, poster: "s-poster")]
            stopped.update(stopItems, after: 0, count: 3, context: "stop", wifiOnly: false)
            let stopStarted = await waitForRequest("/s-video")
            precondition(stopStarted, "Stop case must cancel an already-started download")
            stopped.stop()
            try? await Task.sleep(for: .milliseconds(1_500))
            precondition(contractCache.cached(stopItems[1].mediaURL!, video: true) == nil, "Stopped late result must not persist")
            stopped.update(stopItems, after: 0, count: 3, context: "stop", wifiOnly: false)
            let resumedAfterStop = await waitUntil { contractCache.cached(stopItems[1].mediaURL!, video: true) != nil }
            precondition(resumedAfterStop, "The same retained owner must resume after an explicit update following stop")
            stopped.stop()

            let oldContextItems = [item(94, "x-current"), item(95, "x-video", video: true, poster: "x-poster")]
            let newContextItems = [item(96, "y-current"), item(97, "y-video", video: true, poster: "y-poster")]
            let contextController = MediaPreloader(cache: contractCache, network: Just(true).eraseToAnyPublisher())
            contextController.update(oldContextItems, after: 0, count: 3, context: "old-context", wifiOnly: false)
            let oldStarted = await waitForRequest("/x-video")
            precondition(oldStarted, "Context case must start the old-context download")
            contextController.update(newContextItems, after: 0, count: 3, context: "new-context", wifiOnly: false)
            try? await Task.sleep(for: .milliseconds(1_500))
            precondition(contractCache.cached(oldContextItems[1].mediaURL!, video: true) == nil, "Old-context late result must not persist")
            contextController.stop()

            let clearItems = [item(83, "clear-current"), item(84, "clear-video", video: true, poster: "clear-poster"), item(85, "clear-image")]
            let beforeClear = MediaPreloader(cache: contractCache, network: Just(true).eraseToAnyPublisher())
            beforeClear.update(clearItems, after: 0, count: 3, context: "clear", wifiOnly: false)
            let clearStarted = await waitForRequest("/clear-video")
            precondition(clearStarted, "Clear case must begin an unfinished HTTP download")
            contractCache.clear()
            try? await Task.sleep(for: .milliseconds(1_500))
            let afterClearStats = try await stats()["requests"] as? [String: Int] ?? [:]
            let clearCount = afterClearStats["/clear-video", default: 0]
            precondition(contractCache.cached(clearItems[1].mediaURL!, video: true) == nil, "Clear must discard the late in-flight result")
            precondition(clearCount == 1, "Clear must not restart the canceled request")
            beforeClear.update(clearItems, after: 0, count: 3, context: "clear", wifiOnly: false)
            let resumedRequest = await waitForRequestCount("/clear-video", 2)
            let resumedCache = await waitUntil { contractCache.cached(clearItems[1].mediaURL!, video: true) != nil }
            let resumed = resumedRequest && resumedCache
            precondition(resumed, "A new update must resume prefetch after clear")
            beforeClear.stop()

            try await resetStats()
            let low = MediaCache(directoryURL: root.appendingPathComponent("low-space"), monitorNetwork: false, diagnostics: nil, availableBytesProvider: { 0 })
            let lowController = MediaPreloader(cache: low, network: Just(true).eraseToAnyPublisher())
            let lowItems = [item(86, "low-current"), item(87, "low-video", video: true, poster: "low-poster"), item(88, "low-image")]
            lowController.update(lowItems, after: 0, count: 3, context: "low", wifiOnly: false)
            try? await Task.sleep(for: .milliseconds(300))
            let lowStats = try await stats()["requests"] as? [String: Int] ?? [:]
            precondition(lowStats.isEmpty, "No-space admission must issue no image or video prefetch request")
            lowController.stop()

            let duplicateItems = [item(89, "dup-current"), item(90, "dup-video", video: true, poster: "dup-poster")]
            let duplicate = MediaPreloader(cache: contractCache, network: Just(true).eraseToAnyPublisher())
            duplicate.update(duplicateItems, after: 0, count: 3, context: "duplicate", wifiOnly: false)
            duplicate.update(duplicateItems, after: 0, count: 3, context: "duplicate", wifiOnly: false)
            let duplicateRequest = await waitForRequest("/dup-video")
            precondition(duplicateRequest, "Duplicate-update case must perform the expected video request")
            let duplicateReady = await waitUntil { contractCache.cached(duplicateItems[1].mediaURL!, video: true) != nil }
            precondition(duplicateReady, "Duplicate-update target must complete")
            duplicate.update(duplicateItems, after: 0, count: 3, context: "duplicate", wifiOnly: false)
            try? await Task.sleep(for: .milliseconds(250))
            let duplicateStats = try await stats()["requests"] as? [String: Int] ?? [:]
            precondition(duplicateStats["/dup-video"] == 1, "Repeated updates and an already-cached target must not issue duplicate requests")
            duplicate.stop()

            var freeBytes: Int64 = 2_000_000_000
            let owners = MediaCache(directoryURL: root.appendingPathComponent("owner-protection"), monitorNetwork: false,
                diagnostics: nil, availableBytesProvider: { freeBytes })
            let ownerA = UUID(), ownerB = UUID()
            let addressA = base.appendingPathComponent("owner-a-image"), addressB = base.appendingPathComponent("owner-b-image")
            let savedA = await owners.image(addressA), savedB = await owners.image(addressB)
            precondition(savedA != nil && savedB != nil, "Owner protection starts with two actual decoded fixture files")
            owners.setPrefetchTargets([(addressA, false)], owner: ownerA)
            owners.setPrefetchTargets([(addressB, false)], owner: ownerB)
            freeBytes = 0; owners.trim()
            precondition(owners.cached(addressA, video: false) != nil && owners.cached(addressB, video: false) != nil,
                         "Both independent windows remain protected under eviction pressure")
            owners.removePrefetchTargets(owner: ownerA)
            precondition(owners.cached(addressA, video: false) == nil && owners.cached(addressB, video: false) != nil,
                         "An old owner cannot release another timeline's cache protection")
            owners.removePrefetchTargets(owner: ownerB)
            precondition(owners.cached(addressB, video: false) == nil, "The final owner releases its own files for normal eviction")

            let boundedItems = [item(200, "bounded-current")] + (1...12).map { item(200 + $0, "bounded-image-\($0)") }
            let bounded = MediaPreloader(cache: contractCache, network: Just(true).eraseToAnyPublisher())
            bounded.update(boundedItems, after: 0, count: 10, context: "bounded", wifiOnly: false)
            var peakActive = bounded.snapshot.active
            let boundedReady = await waitUntil {
                peakActive = max(peakActive, bounded.snapshot.active)
                return bounded.snapshot.ready == 10
            }
            precondition(boundedReady && peakActive <= 2, "The largest ten-item window completes using at most two background jobs")
            let boundedStats = try await stats()["requests"] as? [String: Int] ?? [:]
            precondition(boundedStats["/bounded-image-11"] == nil && boundedStats["/bounded-image-12"] == nil,
                         "Preloading does not fetch beyond its selected bounded window")
            bounded.stop()
        #endif

        try await resetStats()
        let focusItems = [item(100, "focus-current"), item(101, "focus-video1", video: true, poster: "focus-poster1"),
                          item(102, "focus-video2", video: true, poster: "focus-poster2"), item(103, "focus-image")]
        #if LEGACY_PREFETCH51
        let firstFocusTask = Task { await cache.prefetch(focusItems, after: 0) }
        let focusStarted = await waitForRequest("/focus-video2")
        precondition(focusStarted, "Baseline focus case must start video2 before moving focus")
        try? await Task.sleep(for: .milliseconds(80))
        firstFocusTask.cancel()
        let restartedFocusTask = Task { await cache.prefetch(focusItems, after: 1) }
        _ = await waitUntil { cache.cached(focusItems[2].mediaURL!, video: true) != nil }
        await restartedFocusTask.value
        #else
        let focusController = MediaPreloader(cache: cache, network: Just(true).eraseToAnyPublisher())
        focusController.update(focusItems, after: 0, count: 3, context: "focus", wifiOnly: false)
        let focusStarted = await waitForRequest("/focus-video2")
        precondition(focusStarted, "Current focus case must start video2 before moving focus")
        try? await Task.sleep(for: .milliseconds(80))
        focusController.update(focusItems, after: 1, count: 3, context: "focus", wifiOnly: false)
        let focusReady = await waitUntil { cache.cached(focusItems[2].mediaURL!, video: true) != nil }
        precondition(focusReady, "Unchanged future video must complete after moving focus")
        focusController.stop()
        #endif
        focusVideo2Requests = (try await stats()["requests"] as? [String: Int] ?? [:])["/focus-video2", default: 0]
        #if LEGACY_PREFETCH51
        precondition(focusVideo2Requests >= 2, "Frozen baseline should reproduce cancel and restart for video2")
        #else
        precondition(focusVideo2Requests == 1, "New preloader must retain the in-flight future video across focus movement")
        #endif

        let firstVideoTimes = rounds.compactMap { $0["firstVideoRequestMs"] as? Int }
        let completionTimes = rounds.compactMap { $0["allFiveCompleteMs"] as? Int }
        let output: [String: Any] = ["mode": legacy ? "baseline51" : "current", "rounds": rounds, "focusVideo2Requests": focusVideo2Requests,
            "observedRangesMs": ["firstVideoRequest": firstVideoTimes.isEmpty ? NSNull() : [firstVideoTimes.min()!, firstVideoTimes.max()!] as Any,
                                 "allFiveComplete": completionTimes.isEmpty ? NSNull() : [completionTimes.min()!, completionTimes.max()!] as Any],
            "coverage": ["expectedPerRound": 5, "observedCompletePerRound": rounds.map { $0["completedFiles"] ?? 0 }],
            "note": "Times are observed wall-clock milliseconds for three local runs; range is not p95."]
        let encoded = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(decoding: encoded, as: UTF8.self))
    }
}
