import Foundation

@main struct LongPrefetchChecks {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count >= 3 else { fatalError("usage: checks BASE_URL MODE") }
        let base = URL(string: CommandLine.arguments[1])!
        let legacy = CommandLine.arguments[2] == "--baseline52"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("long-prefetch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults.standard
        let priorLimit = defaults.object(forKey: "cacheLimitGB")
        defaults.set(1, forKey: "cacheLimitGB")
        defer { if let priorLimit { defaults.set(priorLimit, forKey: "cacheLimitGB") } else { defaults.removeObject(forKey: "cacheLimitGB") } }

        func stats() async throws -> [String: Any] {
            let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        func reset() async throws { _ = try await URLSession.shared.data(from: base.appendingPathComponent("reset")) }
        func requests() async throws -> [String: Int] { try await stats()["requests"] as? [String: Int] ?? [:] }
        func wait(_ timeout: Double = 8, _ condition: () async -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end { if await condition() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
            return await condition()
        }
        func size(_ file: URL?) -> Int? { file.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } }
        func fetch(_ cache: MediaCache, _ path: String) async throws -> URL? {
            let url = base.appendingPathComponent(path)
            #if LEGACY_PREFETCH52
            return await cache.fetch(url, video: true)
            #else
            return try await cache.preloadFile(url, video: true)
            #endif
        }
        func isLimitExceeded(_ error: Error) -> Bool { String(describing: error).localizedCaseInsensitiveContains("limitExceeded") }
        func isLowSpace(_ error: Error) -> Bool { String(describing: error).localizedCaseInsensitiveContains("lowSpace") }

        var rows: [[String: Any]] = []
        let ordinary = MediaCache(directoryURL: root.appendingPathComponent("ordinary"), monitorNetwork: false,
            diagnostics: nil, availableBytesProvider: { 2_000_000_000 })
        try await reset()
        let ordinaryFile = try await fetch(ordinary, "long-96")
        let ordinarySize = size(ordinaryFile)
        if legacy {
            precondition(ordinaryFile == nil, "Frozen build 52 ordinary 64 MiB fetch must reject the 96 MiB response")
        } else {
            precondition(ordinaryFile != nil && ordinarySize == 96 * 1024 * 1024,
                         "Long video preload must save the complete 96 MiB cache workload")
        }
        rows.append(["case": legacy ? "baseline52" : "current53", "fileSizeBytes": ordinarySize as Any? ?? NSNull(),
                     "requestCount": (try await requests())["/long-96", default: 0]])

        if !legacy {
            // A claimed length above the hard cap must be rejected after only the
            // fixture prefix and a few streamed chunks, without creating cache data.
            try await reset()
            defaults.set(5, forKey: "cacheLimitGB")
            let overCapCache = MediaCache(directoryURL: root.appendingPathComponent("over-cap"), monitorNetwork: false,
                diagnostics: nil, availableBytesProvider: { 2_000_000_000 })
            var overCapError = false
            do { _ = try await fetch(overCapCache, "over-cap") }
            catch { overCapError = isLimitExceeded(error) }
            let overCount = try await requests()["/over-cap", default: 0]
            defaults.set(1, forKey: "cacheLimitGB")
            precondition(overCapError && overCapCache.cached(base.appendingPathComponent("over-cap"), video: true) == nil && overCount == 1,
                         "Over-512 MiB content-length must yield limitExceeded without a cached file")
            rows.append(["case": "over-cap", "error": "limitExceeded", "requestCount": overCount,
                         "cached": overCapCache.cached(base.appendingPathComponent("over-cap"), video: true) != nil])

            // Sparse logical cache occupancy exercises quota-derived max shrink
            // without writing hundreds of MiB to disk. The neutral MP4 fixture
            // remains only a small prefix; the sparse tail is not playable media.
            let quota = MediaCache(directoryURL: root.appendingPathComponent("quota-shrink"), monitorNetwork: false,
                diagnostics: nil, availableBytesProvider: { 2_000_000_000 })
            try await reset()
            let seedURL = base.appendingPathComponent("seed-video")
            guard let seed = try await fetch(quota, "seed-video") else { fatalError("seed video cache file missing") }
            let seedHandle = try FileHandle(forWritingTo: seed)
            try seedHandle.truncate(atOffset: 700 * 1024 * 1024)
            try seedHandle.close()
            quota.pin(seedURL)
            let firstPressureURL = base.appendingPathComponent("quota-96")
            let pressureTask = Task { try await fetch(quota, "quota-96") }
            let pressureStarted = await wait { (try? await requests()["/quota-96"]) != nil }
            precondition(pressureStarted, "Quota-shrink transfer reaches loopback after sparse protected occupancy is established")
            let shrunkReservation = quota.pendingDownloadBudget
            precondition(shrunkReservation >= 96 * 1024 * 1024 && shrunkReservation < 512 * 1024 * 1024,
                         "Protected 700 MiB occupancy must shrink the admitted maximum below 512 MiB while retaining room for 96 MiB")
            let pressureFile = try await pressureTask.value
            precondition(size(pressureFile) == 96 * 1024 * 1024 && quota.cached(firstPressureURL, video: true) != nil &&
                         quota.cached(seedURL, video: true) != nil,
                         "The 96 MiB response succeeds and the protected sparse seed remains cached")
            quota.pin(firstPressureURL)
            let firstHeldSize = size(seed)
            let growHandle = try FileHandle(forWritingTo: seed)
            try growHandle.truncate(atOffset: 724 * 1024 * 1024)
            try growHandle.close()
            try await reset()
            var exhaustedError = false
            do { _ = try await fetch(quota, "quota-exhausted") }
            catch { exhaustedError = isLowSpace(error) }
            let exhaustedRequests = try await requests()
            precondition(exhaustedError && exhaustedRequests["/quota-exhausted"] == nil &&
                         quota.cached(seedURL, video: true) != nil && size(seed) == 724 * 1024 * 1024 &&
                         quota.cached(firstPressureURL, video: true) != nil,
                         "Below 8 MiB quota fails lowSpace before HTTP and retains both protected cache files")
            rows.append(["case": "quota-shrink-and-floor", "sparseHeldBeforeBytes": firstHeldSize!,
                         "sparseHeldAtFloorBytes": size(seed)!, "effectiveReservationBytes": shrunkReservation,
                         "downloadedSizeBytes": size(pressureFile)!, "protectedStillCached": quota.cached(seedURL, video: true) != nil && quota.cached(firstPressureURL, video: true) != nil,
                         "exhaustedRequests": exhaustedRequests])
            quota.unpin(seedURL)
            quota.unpin(firstPressureURL)

            // A foreground repair joins a prefetch flight whose quota-derived
            // maximum is too small for its Content-Length. It must retry once
            // at its own limit after that writer exits, keeping one writer at a time.
            let sharedFlight = MediaCache(directoryURL: root.appendingPathComponent("prefetch-repair-share"), monitorNetwork: false,
                diagnostics: nil, availableBytesProvider: { 2_000_000_000 })
            try await reset()
            let sharedSeedURL = base.appendingPathComponent("seed-video")
            guard let sharedSeed = try await fetch(sharedFlight, "seed-video") else { fatalError("shared-flight seed file missing") }
            let sharedSeedHandle = try FileHandle(forWritingTo: sharedSeed)
            try sharedSeedHandle.truncate(atOffset: 800 * 1024 * 1024)
            try sharedSeedHandle.close()
            sharedFlight.pin(sharedSeedURL)
            let sharedURL = base.appendingPathComponent("foreground-40")
            let prefetchTask = Task {
                do { _ = try await fetch(sharedFlight, "foreground-40"); return "success" }
                catch { return String(describing: error) }
            }
            let sharedRequestStarted = await wait { (try? await requests()["/foreground-40"]) != nil }
            precondition(sharedRequestStarted, "Quota-limited prefetch writer is in flight before repair joins")
            let prefetchReservation = sharedFlight.pendingDownloadBudget
            precondition(prefetchReservation >= 8 * 1024 * 1024 && prefetchReservation < 40 * 1024 * 1024,
                         "The pinned 800 MiB seed constrains the first writer below the 40 MiB response")
            let repairTask = Task<(URL?, String?), Never> {
                do { return (try await sharedFlight.repairOriginal(sharedURL, progress: { _, _ in }), nil as String?) }
                catch { return (nil, String(describing: error)) }
            }
            try await Task.sleep(for: .milliseconds(100))
            precondition(sharedFlight.pendingDownloadBudget == prefetchReservation,
                         "Joining foreground repair does not reserve a second writer while prefetch owns the URL")
            _ = try await URLSession.shared.data(from: base.appendingPathComponent("release-foreground40"))
            let prefetchOutcome = await prefetchTask.value
            let repairOutcome = await repairTask.value
            let sharedFlightRequests = try await requests()
            precondition(prefetchOutcome.localizedCaseInsensitiveContains("lowSpace") && repairOutcome.0 != nil &&
                         size(repairOutcome.0) == 40 * 1024 * 1024 && sharedFlight.pendingDownloadBudget == 0 &&
                         sharedFlightRequests["/foreground-40"] == 2,
                         "Prefetch receives lowSpace; repair retries after its smaller writer and saves 40 MiB with exactly two serial GETs")
            rows.append(["case": "prefetch-to-repair-shared-flight", "initialReservationBytes": prefetchReservation,
                         "prefetchOutcome": prefetchOutcome, "repairSizeBytes": size(repairOutcome.0)!,
                         "requestCount": sharedFlightRequests["/foreground-40", default: 0],
                         "pendingDownloadBudget": sharedFlight.pendingDownloadBudget])
            sharedFlight.unpin(sharedSeedURL)

            // Below the 8 MiB admission floor, no HTTP request may be issued.
            let tiny = MediaCache(directoryURL: root.appendingPathComponent("tiny"), monitorNetwork: false,
                diagnostics: nil, availableBytesProvider: { 1_000_000_000 + 7 * 1024 * 1024 })
            try await reset()
            var tinyError = false
            do { _ = try await fetch(tiny, "long-96") }
            catch { tinyError = isLowSpace(error) }
            let tinyRequests = try await requests()
            precondition(tinyError && tinyRequests["/long-96"] == nil,
                         "Less than 8 MiB available must fail lowSpace before any HTTP request")
            rows.append(["case": "below-minimum", "error": "lowSpace", "requests": tinyRequests])

            // Shared reservation allows A's single 96 MiB transfer in 160 MiB
            // headroom and refuses B until the first flight releases its reservation.
            let shared = MediaCache(directoryURL: root.appendingPathComponent("shared"), monitorNetwork: false,
                diagnostics: nil, availableBytesProvider: { 1_000_000_000 + 160 * 1024 * 1024 })
            try await reset()
            let aTask = Task { try await fetch(shared, "shared-a") }
            let aStarted = await wait { (try? await requests()["/shared-a"]) != nil }
            precondition(aStarted, "A must begin before B is admitted")
            let sharedConsumer = Task { try await fetch(shared, "shared-a") }
            let bTask = Task { try await fetch(shared, "shared-b") }
            var bLowSpace = false
            do { _ = try await bTask.value } catch { bLowSpace = isLowSpace(error) }
            let a = try await aTask.value
            let sameA = try await sharedConsumer.value
            precondition(a == sameA, "Two consumers share the same completed large file")
            let sharedOwner = UUID(); shared.setPrefetchTargets([(base.appendingPathComponent("shared-a"), true)], owner: sharedOwner)
            precondition(size(a) == 96 * 1024 * 1024 && bLowSpace && shared.pendingDownloadBudget == 0,
                         "A completes, B is refused within shared 160 MiB headroom, and the reservation returns to zero")
            let bRetry = try await fetch(shared, "shared-b")
            precondition(size(bRetry) == 96 * 1024 * 1024 && shared.pendingDownloadBudget == 0,
                         "B can retry after A's owner releases the budget")
            let sharedRequests = try await requests()
            precondition(sharedRequests["/shared-a"] == 1 && sharedRequests["/shared-b"] == 1,
                         "The refused attempt sends no request; explicit retry sends exactly one")
            rows.append(["case": "shared-budget", "aSizeBytes": size(a)!, "bSizeBytes": size(bRetry)!,
                         "pendingDownloadBudget": shared.pendingDownloadBudget, "requests": sharedRequests])

            shared.removePrefetchTargets(owner: sharedOwner)

            // Cancellation closes the response stream, removes the partial file,
            // and releases the whole flight reservation.
            let cancelled = MediaCache(directoryURL: root.appendingPathComponent("cancelled"), monitorNetwork: false,
                diagnostics: nil, availableBytesProvider: { 1_000_000_000 + 160 * 1024 * 1024 })
            try await reset()
            let cancelURL = base.appendingPathComponent("cancel-long")
            let cancelTask = Task { try await fetch(cancelled, "cancel-long") }
            let cancelStarted = await wait { cancelled.pendingDownloadBudget > 0 }
            precondition(cancelStarted, "Cancellation case observes a reserved long download")
            cancelTask.cancel()
            do { _ = try await cancelTask.value } catch { }
            let clean = await wait { cancelled.pendingDownloadBudget == 0 }
            precondition(clean && cancelled.cached(cancelURL, video: true) == nil,
                         "Cancelled long prefetch leaves no final cache file and releases its reservation")
            rows.append(["case": "cancelled", "pendingDownloadBudget": cancelled.pendingDownloadBudget,
                         "cached": cancelled.cached(cancelURL, video: true) != nil])
        }
        let compiledSourceHash = ProcessInfo.processInfo.environment["LONG_PREFETCH_SOURCE_HASH"] ?? "not-provided"
        print(try JSONSerialization.data(withJSONObject: ["mode": legacy ? "baseline52" : "current53",
            "compiledSourceHash": compiledSourceHash, "checks": rows], options: [.sortedKeys]).utf8String)
    }
}

private extension Data { var utf8String: String { String(decoding: self, as: UTF8.self) } }
