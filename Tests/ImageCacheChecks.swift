import Foundation
import CryptoKit
import ImageIO
import Combine

@main struct ImageCacheChecks {
    @MainActor static func main() async throws {
        let base = URL(string: CommandLine.arguments[1])!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("image-cache-checks-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MediaCache(directoryURL: root.appendingPathComponent("cache"), monitorNetwork: false, diagnostics: nil)
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message); checks += 1 }
        check(cache.diskUsageKnown && cache.diskBytes == 0, "A successfully scanned empty cache is a known zero")
        let cacheFolder = root.appendingPathComponent("cache")
        try FileManager.default.removeItem(at: cacheFolder)
        try Data("directory unavailable".utf8).write(to: cacheFolder)
        cache.trim()
        check(!cache.diskUsageKnown, "An unreadable cache directory must not be presented as zero bytes")
        check(cache.reserveRepairBudget() == 0, "Unknown cache usage never admits conversion output")
        try FileManager.default.removeItem(at: cacheFolder)
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        cache.trim()
        check(cache.diskUsageKnown && cache.diskBytes == 0, "A subsequent successful scan restores known empty usage")
        func address(_ path: String) -> URL { base.appendingPathComponent(path) }
        func target(_ url: URL) -> URL {
            let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() + ".img"
            return root.appendingPathComponent("cache").appendingPathComponent(name)
        }
        func stats() async throws -> [String: Any] {
            let (data, _) = try await URLSession.shared.data(from: address("stats")); return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        let asset = "https://image.civitai.com/public-prefix/1B8CB1F8-AC2B-4E7D-93D0-0D2BF22F3BA1/original=true,blur=15/clip.mp4"
        let still = MediaPosterPolicy.stillURL(URL(string: asset)!)!
        check(still.host == "image.civitai.com" && still.path.hasPrefix("/public-prefix/1B8CB1F8-AC2B-4E7D-93D0-0D2BF22F3BA1/"), "Poster preserves exact CDN namespace and asset")
        check(still.path.contains("blur=15") && still.path.contains("transcode=true") && still.path.contains("anim=false") && still.path.contains("width=450"), "Poster retains blur while requesting documented bounded still format")
        check(!still.path.contains("original=true") && still.path.hasSuffix("poster.jpeg"), "Original MP4 option is replaced only for still delivery")
        for raw in [asset + "?signature=fixture", asset + "#fragment", "https://foreign.test/1B8CB1F8-AC2B-4E7D-93D0-0D2BF22F3BA1/clip.mp4", "https://image.civitai.com/no-stable-asset/clip.mp4"] {
            check(MediaPosterPolicy.stillURL(URL(string: raw)!) == nil, "Unknown or signed source is never rewritten")
        }
        if CommandLine.arguments.contains("--probe-mime") {
            var result: [String: String] = [:]
            for path in ["mislabel-image", "video-header-image", "no-type-image"] {
                do { let image = try await cache.loadImage(address(path)); result[path] = image.size.width > 0 ? "DECODED" : "EMPTY" }
                catch MediaDownloadError.notImage { result[path] = "REJECTED_BY_MIME_NOT_IMAGE" }
                catch { result[path] = "OTHER_FAILURE" }
            }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self)); return
        }
        var images = 0
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for index in 0..<12 { group.addTask { let image = try await cache.loadImage(address("image-\(index)")); return image.size.width > 0 } }
            for try await valid in group { if valid { images += 1 } }
        }
        check(images == 12, "All twelve grid thumbnails wait for admission and decode")
        let firstStats = try await stats()
        check((firstStats["maxActive"] as? Int ?? 100) <= 4, "Network transfer concurrency stays at four")
        let badURL = address("recover")
        do { _ = try await cache.loadImage(badURL); preconditionFailure("Invalid image bytes decoded") }
        catch ImageLoadError.decode { checks += 1 }
        check(!FileManager.default.fileExists(atPath: target(badURL).path), "Invalid image body is not stored")
        _ = try await cache.loadImage(badURL)
        check(FileManager.default.fileExists(atPath: target(badURL).path), "A later valid response repairs the same request")
        let largeImage = address("large-image")
        let largeDecoded = try await cache.loadImage(largeImage)
        check(largeDecoded.size.width > 0, "A valid synthetic image larger than 16 MiB decodes")
        check(FileManager.default.fileExists(atPath: target(largeImage).path), "A valid synthetic image larger than 16 MiB is cached")
        let oversizedImage = address("oversized-image")
        do { _ = try await cache.loadImage(oversizedImage); preconditionFailure("Image larger than 64 MiB was accepted") }
        catch MediaDownloadError.limitExceeded { checks += 1 }
        check(!FileManager.default.fileExists(atPath: target(oversizedImage).path), "An image larger than 64 MiB is canceled and never cached")
        let limitedCacheFolder = root.appendingPathComponent("limited-cache", isDirectory: true)
        let freeBytes = Int64(1_000_000_000 + 8 * 1024 * 1024)
        let limitedCache = MediaCache(directoryURL: limitedCacheFolder, monitorNetwork: false, diagnostics: nil,
            availableBytesProvider: { freeBytes })
        let quotaImage = address("quota-image")
        do { _ = try await limitedCache.preloadFile(quotaImage, video: false); preconditionFailure("Insufficient image preload quota was accepted") }
        catch ImageLoadError.lowSpace { checks += 1 }
        let quotaTarget = limitedCacheFolder.appendingPathComponent(SHA256.hash(data: Data(quotaImage.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() + ".img")
        check(!FileManager.default.fileExists(atPath: quotaTarget.path), "A quota-limited preload leaves no partial image in cache")
        check(limitedCache.pendingDownloadBudget == 0 && limitedCache.diskBytes == 0 && freeBytes == 1_000_000_000 + 8 * 1024 * 1024,
            "A rejected dynamic preload quota releases reservations and leaves cache and available-space accounting unchanged")
        var sharedFreeBytes = Int64(1_000_000_000 + 8 * 1024 * 1024)
        let sharedCacheFolder = root.appendingPathComponent("shared-quota-cache", isDirectory: true)
        let sharedCache = MediaCache(directoryURL: sharedCacheFolder, monitorNetwork: false, diagnostics: nil,
            availableBytesProvider: { sharedFreeBytes })
        let sharedQuotaImage = address("shared-quota-image")
        let sharedPreload = Task { () -> String in
            do { _ = try await sharedCache.preloadFile(sharedQuotaImage, video: false); return "SUCCESS" }
            catch ImageLoadError.lowSpace { return "LOW_SPACE" }
            catch { return String(describing: error) }
        }
        for _ in 0..<100 {
            let counts = try await stats()["requests"] as? [String: Int] ?? [:]
            if counts["/shared-quota-image"] == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let waitingStats = try await stats()
        check((waitingStats["requests"] as? [String: Int] ?? [:])["/shared-quota-image"] == 1,
            "The quota-limited preload reaches the loopback server before the foreground consumer joins")
        let foreground = Task { try await sharedCache.loadImage(sharedQuotaImage) }
        try await Task.sleep(for: .milliseconds(50))
        sharedFreeBytes = 1_100_000_000
        let foregroundImage = try await foreground.value
        check(foregroundImage.size.width > 0, "The foreground consumer re-admits and decodes the image after preload quota failure")
        let preloadResult = await sharedPreload.value
        check(preloadResult == "LOW_SPACE", "The original prefetch caller retains its low-space result (\(preloadResult))")
        let sharedQuotaStats = try await stats()
        let sharedQuotaRequests = sharedQuotaStats["requests"] as? [String: Int] ?? [:]
        check(sharedQuotaRequests["/shared-quota-image"] == 2,
            "Shared quota failure is followed by exactly one foreground retry")
        check((sharedQuotaStats["sameURLMax"] as? Int ?? 0) == 1,
            "The shared URL never has concurrent HTTP writers during foreground re-admission")
        let sharedQuotaTarget = sharedCacheFolder.appendingPathComponent(SHA256.hash(data: Data(sharedQuotaImage.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() + ".img")
        check(FileManager.default.fileExists(atPath: sharedQuotaTarget.path), "The foreground retry commits its decoded image to cache")
        check(sharedCache.pendingDownloadBudget == 0, "Both shared-flight reservations are released after re-admission")
        let sharedTempFiles = (try FileManager.default.contentsOfDirectory(at: sharedCacheFolder, includingPropertiesForKeys: nil))
        check(sharedTempFiles.count == 1 && sharedTempFiles.first?.standardizedFileURL == sharedQuotaTarget.standardizedFileURL,
            "No partial or unfinished image file remains after shared quota re-admission: \(sharedTempFiles.map(\.path)); expected \(sharedQuotaTarget.path)")
        let oldBadURL = address("old-bad-cache")
        try Data("old corrupt cache".utf8).write(to: target(oldBadURL))
        _ = try await cache.loadImage(oldBadURL)
        let repairedBytes = try Data(contentsOf: target(oldBadURL))
        check(repairedBytes.count > 32, "A legacy corrupt cache entry self-heals")
        let jpeg = root.appendingPathComponent("native-fixture.jpeg")
        let cgSource = CGImageSourceCreateWithData(repairedBytes as CFData, nil)!
        let cgImage = CGImageSourceCreateImageAtIndex(cgSource, 0, nil)!
        let destination = CGImageDestinationCreateWithURL(jpeg as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cgImage, nil)
        check(CGImageDestinationFinalize(destination), "Native synthetic JPEG fixture encoded")
        _ = try await cache.loadImage(jpeg); checks += 1
        for (path, code) in [("http404", 404), ("http429", 429)] {
            do { _ = try await cache.loadImage(address(path)); preconditionFailure("HTTP failure accepted") }
            catch MediaDownloadError.http(let actual) { check(actual == code, "HTTP status is distinguishable") }
            check(!FileManager.default.fileExists(atPath: target(address(path)).path), "HTTP failures never become cache hits")
        }
        do { _ = try await cache.loadImage(address("video-poster")); preconditionFailure("Video body accepted as image") }
        catch MediaDownloadError.videoContent { checks += 1 }
        check(!FileManager.default.fileExists(atPath: target(address("video-poster")).path), "Video poster body is not stored as .img")
        _ = try await cache.loadImage(address("octet-image")); checks += 1
        for path in ["mislabel-image", "video-header-image", "no-type-image"] {
            _ = try await cache.loadImage(address(path)); checks += 1
        }
        _ = try await cache.loadImage(address("redirect-image")); checks += 1
        do { _ = try await cache.loadPoster(source: address("must-not-fetch-after-403"), declared: address("redirect-403"), allowExtraction: true); preconditionFailure("Access denial bypassed") }
        catch MediaDownloadError.http(let status) { check(status == 403, "Final redirect HTTP status is preserved") }
        let deniedStats = try await stats()["requests"] as? [String: Int] ?? [:]
        check(deniedStats["/must-not-fetch-after-403"] == nil, "403 never switches to another poster or media source")
        check(cache.cached(address("video-poster"), video: true) != nil, "Actually playable video mislabeled as image is retained under video cache format")
        for path in ["html-body", "json-body"] {
            do { _ = try await cache.loadImage(address(path)); preconditionFailure("Non-media body accepted") }
            catch MediaDownloadError.notImage { checks += 1 }
            check(!FileManager.default.fileExists(atPath: target(address(path)).path), "Error body not cached as an image")
        }
        for path in ["animated-gif", "animated-webp"] {
            let resource = try await cache.imageResource(address(path))
            check(resource.frameCount > 1, "Actual animation is detected without trusting extension/header")
            let animation = try MediaImageDecoder.animation(resource.file)
            check(animation.frames.count > 1 && animation.frames.count <= 32, "Animation frames decoded within bound")
            check(animation.frames.allSatisfy { max($0.width, $0.height) <= 384 }, "Animation pixels stay bounded")
            check(animation.duration > 0 && animation.duration <= 120, "Animation duration is valid")
            let first = animation.frames.first!.dataProvider!.data! as Data
            check(animation.frames.dropFirst().contains { ($0.dataProvider!.data! as Data) != first }, "Different animation frame pixels actually decoded")
            let reload = try await cache.imageResource(address(path))
            check(reload.frameCount == resource.frameCount, "Cached raw animation survives reloading")
        }
        var posterWrites: [String] = []
        let posterObserver = cache.posterUpdates.sink { posterWrites.append($0) }
        defer { posterObserver.cancel() }
        let poster = try await cache.loadPoster(source: address("short-video"), declared: address("video-poster"), allowExtraction: true)
        check(poster.size.width > 0 && max(poster.size.width, poster.size.height) <= 512, "Valid MP4 yields bounded first-frame poster")
        check(posterWrites == [cache.posterCacheKey(for: address("short-video"))], "Local extraction publishes only its successfully committed poster key")
        check(posterWrites[0].count == 68 && posterWrites[0].hasSuffix(".jpg") && !posterWrites[0].contains("127.0.0.1"), "Invalidation uses the existing hashed disk identity without retaining a source URL")
        let beforePosterCache = try await stats()["requests"] as? [String: Int] ?? [:]
        _ = try await cache.loadPoster(source: address("short-video"), declared: nil, allowExtraction: true)
        check(posterWrites.count == 1, "A cache hit does not publish and cannot create a refresh loop")
        let afterPosterCache = try await stats()["requests"] as? [String: Int] ?? [:]
        check(afterPosterCache["/short-video"] == beforePosterCache["/short-video"], "Generated poster reused without re-downloading video")
        do { _ = try await cache.loadPoster(source: address("no-grid-video-download"), declared: nil, allowExtraction: false); preconditionFailure("Grid downloaded video for poster") }
        catch MediaDownloadError.videoContent { checks += 1 }

        // An undecodable original can already have a validated native derivative.
        // A static detail preview may reuse it without fetching or re-converting.
        let repairedAddress = address("local-repaired-poster")
        let posterOriginal = cacheFolder.appendingPathComponent(MediaRepairStore.addressKey(repairedAddress) + ".mp4")
        try Data([0x1a, 0x45, 0xdf, 0xa3] + Array(repeating: UInt8(0), count: 64)).write(to: posterOriginal)
        let digest = try MediaRepairStore.contentHash(posterOriginal)
        let derivative = cacheFolder.appendingPathComponent(MediaRepairStore.outputName(repairedAddress, content: digest, transcoded: false))
        let validVideo = cache.cached(address("video-poster"), video: true)!
        try FileManager.default.copyItem(at: validVideo, to: derivative)
        try MediaRepairStore.commit(repairedAddress, original: posterOriginal, content: digest, transcoded: false, output: derivative, directory: cacheFolder)
        let reusedPoster = try await cache.loadPoster(source: repairedAddress, declared: nil, allowExtraction: false, allowLocalExtraction: true)
        check(reusedPoster.size.width > 0, "Local-only detail preview extracts the existing compatible derivative instead of the bad original")
        let localPosterStats = try await stats()["requests"] as? [String: Int] ?? [:]
        check(localPosterStats["/local-repaired-poster"] == nil, "Local derivative poster never downloads the original")
        do { _ = try await cache.loadPoster(source: address("missing-local-poster"), declared: nil, allowExtraction: false, allowLocalExtraction: true); preconditionFailure("Local-only preview downloaded a video") }
        catch MediaDownloadError.videoContent { checks += 1 }
        let missingPosterStats = try await stats()["requests"] as? [String: Int] ?? [:]
        check(missingPosterStats["/missing-local-poster"] == nil, "Missing local files stay unavailable without a network fallback")
        let capturedAddress = address("captured-native-frame")
        let capturedBytes = try Data(contentsOf: jpeg)
        let beforeCapturedWrites = posterWrites.count
        try cache.storeGeneratedPoster(capturedBytes, source: capturedAddress, expectedGeneration: cache.repairGeneration)
        check(posterWrites.count == beforeCapturedWrites + 1 && posterWrites.last == cache.posterCacheKey(for: capturedAddress), "A native producer immediately invalidates exactly this source after committing a valid JPEG")
        check(posterWrites.last != cache.posterCacheKey(for: address("unrelated-work")), "The write signal cannot be confused with another work")
        var capturedStage = PosterDiagnosticStage.declaredImage
        _ = try await cache.loadPoster(source: capturedAddress, declared: address("must-not-request-declared-cover"), allowExtraction: false,
            onStage: { capturedStage = $0 })
        check(posterWrites.count == beforeCapturedWrites + 1, "Reading the new native frame does not republish its write")
        check(capturedStage == .cachedPoster && cache.hasGeneratedPoster(capturedAddress), "A player-frame JPEG is reused under the same source identity before a remote request")
        let capturedStats = try await stats()["requests"] as? [String: Int] ?? [:]
        check(capturedStats["/must-not-request-declared-cover"] == nil, "A generated frame does not refetch the failed declared thumbnail")
        do { try cache.storeGeneratedPoster(capturedBytes, source: address("stale-generated"), expectedGeneration: cache.repairGeneration - 1); preconditionFailure("Stale generation committed a frame") }
        catch is CancellationError { checks += 1 }
        do { try cache.storeGeneratedPoster(Data("notjpeg".utf8), source: address("invalid-generated"), expectedGeneration: cache.repairGeneration); preconditionFailure("Invalid generated image accepted") }
        catch ImageLoadError.decode { checks += 1 }
        check(posterWrites.count == beforeCapturedWrites + 1, "Rejected stale and invalid writes cannot notify previews")
        check(PosterDiagnosticPolicy.failure(ImageLoadError.decode, stage: .declaredImage) == .decode &&
              PosterDiagnosticPolicy.failure(MediaDownloadError.limitExceeded, stage: .declaredImage) == .limitExceeded,
              "Typed errors remain distinct even when NSError integer codes collide")

        let localClip = root.appendingPathComponent("poster50-local.mp4")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/short.mp4"), to: localClip)
        let corruptJPEG = root.appendingPathComponent("poster50-corrupt.jpeg")
        try Data(Data(contentsOf: jpeg).prefix(20)).write(to: corruptJPEG)
        var localStages: [PosterDiagnosticStage] = []
        let localRecovered = try await cache.loadPoster(source: localClip, declared: corruptJPEG, allowExtraction: false,
            allowLocalExtraction: true, onStage: { localStages.append($0) })
        check(localRecovered.size.width > 0 && localStages.contains(.localFrame), "A broken declared JPEG can recover from this exact already-local valid video")
        check(cache.hasGeneratedPoster(localClip), "A recovered local frame is reusable under the original source key")
        let evictingCache = MediaCache(directoryURL: root.appendingPathComponent("immediate-eviction"), monitorNetwork: false,
            diagnostics: nil, availableBytesProvider: { 0 })
        var evictedWrites: [String] = []
        let evictionObserver = evictingCache.posterUpdates.sink { evictedWrites.append($0) }
        defer { evictionObserver.cancel() }
        let evictedPreview = try await evictingCache.loadPoster(source: localClip, declared: corruptJPEG,
            allowExtraction: false, allowLocalExtraction: true)
        check(evictedPreview.size.width > 0, "Low space still returns the successfully extracted in-memory preview")
        check(!evictingCache.hasGeneratedPoster(localClip) && evictingCache.diskBytes == 0, "The existing zero cache budget immediately evicts its generated disk poster")
        print("PosterEvictionProbe: retained=\(evictingCache.hasGeneratedPoster(localClip));notifications=\(evictedWrites.count)")
        check(evictedWrites.isEmpty, "An immediately evicted poster must not notify and restart its own extractor")
        do { try evictingCache.storeGeneratedPoster(capturedBytes, source: localClip,
            expectedGeneration: evictingCache.repairGeneration); preconditionFailure("Low-space native frame was committed") }
        catch ImageLoadError.lowSpace { checks += 1 }
        check(evictedWrites.isEmpty, "A low-space rejected native write does not signal cache availability")
        let unavailable = address("must-not-fetch-on-poster-decode")
        var coldStage = PosterDiagnosticStage.cachedPoster
        do { _ = try await cache.loadPoster(source: unavailable, declared: corruptJPEG, allowExtraction: false,
            allowLocalExtraction: true, onStage: { coldStage = $0 }); preconditionFailure("Missing local media silently became a poster") }
        catch ImageLoadError.decode { checks += 1 }
        check(coldStage == .declaredImage, "If local recovery is unavailable, the original decode failure and stage remain visible")
        let coldRequests = try await stats()["requests"] as? [String: Int] ?? [:]
        check(coldRequests["/must-not-fetch-on-poster-decode"] == nil, "Decode recovery never downloads the source video")
        let deniedClip = root.appendingPathComponent("poster50-denied.mp4")
        try FileManager.default.copyItem(at: localClip, to: deniedClip)
        do { _ = try await cache.loadPoster(source: deniedClip, declared: address("http403"), allowExtraction: false,
            allowLocalExtraction: true); preconditionFailure("A denied declared cover was bypassed") }
        catch MediaDownloadError.http(let status) { check(status == 403, "A403 remains a403 even when a valid local video exists") }
        check(!cache.hasGeneratedPoster(deniedClip), "No frame is generated after an explicit access denial")
        for (name, body) in [("html", "<!doctype html><html><form>Login</form></html>"),
                             ("comment-html", "<!-- gateway -->\n<!doctype html><html><form>Login</form></html>"),
                             ("json", "{\"error\":\"authentication\"}")] {
            let document = root.appendingPathComponent("poster50-\(name).jpeg")
            try Data(body.utf8).write(to: document)
            do { _ = try await cache.loadPoster(source: deniedClip, declared: document, allowExtraction: false,
                allowLocalExtraction: true); preconditionFailure("An error document was treated as a damaged image") }
            catch MediaDownloadError.notImage { checks += 1 }
            check(!cache.hasGeneratedPoster(deniedClip), "A mislabeled error document cannot trigger local frame recovery")
        }
        var generationChangedDuringFrame = false
        do {
            _ = try await cache.loadPoster(source: deniedClip, declared: corruptJPEG, allowExtraction: false,
                allowLocalExtraction: true, onStage: { stage in
                    if stage == .localFrame { cache.clear(); generationChangedDuringFrame = true }
                })
            preconditionFailure("A stale generation local frame was accepted")
        } catch is CancellationError {
            check(generationChangedDuringFrame && !Task.isCancelled,
                  "Cache-generation cancellation is preserved even though the calling task was not cancelled")
        }
        check(!cache.hasGeneratedPoster(deniedClip), "A generation change during local frame extraction cannot write a poster")

        let shared = address("shared-image")
        let one = Task { try await cache.loadImage(shared) }, two = Task { try await cache.loadImage(shared) }
        try await Task.sleep(for: .milliseconds(80)); one.cancel()
        do { _ = try await one.value; preconditionFailure("Cancelled consumer succeeded") } catch is CancellationError { checks += 1 }
        _ = try await two.value
        let sharedStats = try await stats()
        let requests = sharedStats["requests"] as? [String: Int] ?? [:]
        check(requests["/shared-image"] == 1, "Canceling one consumer preserves the other shared download")
        let blockers = (0..<4).map { index in Task { try await cache.loadImage(address("block-\(index)")) } }
        for _ in 0..<30 {
            let counts = try await stats()["requests"] as? [String: Int] ?? [:]
            if (0..<4).allSatisfy({ counts["/block-\($0)"] == 1 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let queued = Task { try await cache.loadImage(address("cancel-queued")) }
        try await Task.sleep(for: .milliseconds(30)); queued.cancel()
        do { _ = try await queued.value; preconditionFailure("Cancelled queued image succeeded") } catch is CancellationError { checks += 1 }
        for blocker in blockers { _ = try await blocker.value }
        let afterQueue = try await stats()["requests"] as? [String: Int] ?? [:]
        check(afterQueue["/cancel-queued"] == nil, "Canceled queued image never reaches the server")
        let outside = root.appendingPathComponent("offline-kept.bin")
        try Data("preserve offline data".utf8).write(to: outside)
        let clearing = Task { try await cache.loadImage(address("clear-active")) }
        try await Task.sleep(for: .milliseconds(80)); cache.clear()
        do { _ = try await clearing.value; preconditionFailure("Cleared job returned a late cache write") } catch is CancellationError { checks += 1 }
        check(!FileManager.default.fileExists(atPath: target(address("clear-active")).path), "Clear rejects late cache writes")
        check(FileManager.default.fileExists(atPath: outside.path), "Cache cleanup preserves files outside its directory")
        let local = root.appendingPathComponent("local-invalid.img"); try Data("not an image".utf8).write(to: local)
        do { _ = try await cache.loadImage(local); preconditionFailure("Invalid local image accepted") } catch ImageLoadError.decode { checks += 1 }
        check(FileManager.default.fileExists(atPath: local.path), "Invalid offline/local source is preserved")
        let repairSource = address("short-video")
        let original = try await cache.repairOriginal(repairSource) { _, _ in }
        check(FileManager.default.fileExists(atPath: original.path), "Repair source uses the normal bounded cache")
        cache.pin(repairSource); cache.pin(repairSource); cache.unpin(repairSource)
        let generationBeforeClear = cache.repairGeneration
        cache.clear()
        check(cache.repairGeneration != generationBeforeClear, "Clear invalidates any pending repair commit")
        check(FileManager.default.fileExists(atPath: original.path), "One consumer cannot release another original pin")
        cache.unpin(repairSource); cache.clear()
        check(!FileManager.default.fileExists(atPath: original.path), "Last original pin releases cache ownership")
        let partial = cache.repairDirectory.appendingPathComponent("cvr1-synthetic.partial")
        try Data(repeating: 1, count: 128).write(to: partial)
        cache.protectRepairFile(partial); cache.protectRepairFile(partial); cache.unprotectRepairFile(partial)
        cache.clear()
        check(FileManager.default.fileExists(atPath: partial.path), "Partial-file pins are reference counted")
        cache.unprotectRepairFile(partial); cache.clear()
        check(!FileManager.default.fileExists(atPath: partial.path), "Released partial files remain clearable")
        check(FileManager.default.fileExists(atPath: outside.path), "Repair cleanup leaves offline scope untouched")
        let largeAddress = address("large-video")
        let smallFlight = Task { await cache.fetch(largeAddress, video: true) }
        try await Task.sleep(for: .milliseconds(50))
        let largerRepair = Task { try await cache.repairOriginal(largeAddress) { _, _ in } }
        let smallResult = await smallFlight.value
        check(smallResult == nil, "Ordinary prefetch retains its 64MiB limit")
        let largeFile = try await largerRepair.value
        let largeSize = (try largeFile.resourceValues(forKeys: [.fileSizeKey])).fileSize
        check(largeSize == 65 * 1024 * 1024, "Repair retries finished smaller flight once with its larger limit")
        let largeRequests = try await stats()["requests"] as? [String: Int] ?? [:]
        check(largeRequests["/large-video"] == 2, "Exactly one bounded larger request follows smaller-flight limit failure")
        print("ImageCacheChecks: \(checks) actual queue, decode, retry, cancellation and storage assertions passed")
    }
}
