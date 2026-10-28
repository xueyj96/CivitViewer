import Foundation
import UIKit
import CryptoKit
import Network
import Combine
import ImageIO
import AVFoundation

struct CachedImageResource {
    let file: URL
    let preview: UIImage
    let frameCount: Int
}

struct MediaPreloadStatus: Equatable {
    var ready = 0, total = 0, target = 0, running = 0, failed = 0
    var networkPaused = 0, oversized = 0, spaceLimited = 0, networkFailed = 0
    var paused = false
    var summary: String {
        guard target > 0 else { return "暂无预载任务" }
        return (paused ? "上次准备 " : "已准备 ") + "\(ready)/\(target)" + (paused ? " · 已暂停" : (running > 0 ? " · 下载中 \(running)" : ""))
    }
    var detail: String {
        var parts: [String] = []
        if total < target { parts.append("当前列表仅有 \(total) 条后续作品") }
        if networkPaused > 0 { parts.append("\(networkPaused) 条等待允许的网络") }
        if oversized > 0 { parts.append("\(oversized) 条超过单条预取上限") }
        if spaceLimited > 0 { parts.append("\(spaceLimited) 条空间或缓存写入受限") }
        if networkFailed > 0 { parts.append("\(networkFailed) 条网络读取失败") }
        if failed > oversized + spaceLimited + networkFailed { parts.append("另有作品读取失败") }
        if paused { parts.append("返回观看页后继续") }
        return parts.joined(separator: "；")
    }
}

enum PosterDiagnosticPolicy {
    static func failure(_ error: Error, stage: PosterDiagnosticStage) -> PosterFailureKind {
        if let error = error as? ImageLoadError {
            switch error {
            case .queueFull: return .queueFull
            case .decode: return .decode
            case .lowSpace: return .lowSpace
            case .missingLocal: return .missingLocal
            case .cacheWrite: return .cacheWrite
            case .animationLimit: return .animationLimit
            }
        }
        if let error = error as? MediaDownloadError {
            switch error {
            case .limitExceeded: return .limitExceeded
            case .http: return .http
            case .notImage: return .notImage
            case .videoContent: return .videoContent
            }
        }
        if (error as NSError).domain == NSURLErrorDomain { return .network }
        if stage == .localFrame || stage == .decodedFrame { return .nativeFrame }
        if stage == .cacheWrite { return .cacheWrite }
        return .unknown
    }
}

/// Cache keys are hashes, never a persisted URL/token manifest. App cache files
/// are excluded from backups, bounded, and removable from native settings.
@MainActor
final class MediaCache: ObservableObject {
    static let shared = MediaCache()
    @Published private(set) var diskBytes: Int64 = 0
    @Published private(set) var diskUsageKnown = false
    @Published private(set) var cacheHits = 0
    @Published private(set) var preloadStatus: MediaPreloadStatus?
    private var preloadStatusOwner: UUID?
    private let memory = NSCache<NSURL, UIImage>()
    private let posterWrites = PassthroughSubject<String, Never>()
    /// In-process invalidation only. Keys reuse the hashed disk identity; no URL
    /// manifest or event history is retained, and cache hits never publish.
    var posterUpdates: AnyPublisher<String, Never> { posterWrites.eraseToAnyPublisher() }
    private struct Flight { let id: UUID; let task: Task<URL, Error>; var maximum: Int64; var consumers: Set<UUID> }
    private struct PreloadQuotaFailure: Error { let maximum: Int64 }
    private var inFlight: [String: Flight] = [:]
    private let downloads = MediaLoadQueue()
    private let posterJobs = MediaLoadQueue(limit: 1, maximumWaiting: 2)
    private var pinned: [String: Int] = [:]
    private var repairPins: [String: Int] = [:]
    private var repairReserved: Int64 = 0
    private var downloadReserved: Int64 = 0
    var pendingDownloadBudget: Int64 { downloadReserved }
    private var upcoming: [UUID: Set<String>] = [:]
    private let directory: URL
    private let diagnostics: LocalDiagnosticsStore?
    private let availableBytesProvider: (() -> Int64?)?
    private let monitor = NWPathMonitor()
    @Published private(set) var unmetered = false
    @Published private(set) var generation = 0
    var prefetchNetwork: AnyPublisher<Bool, Never> { $unmetered.eraseToAnyPublisher() }
    var prefetchInvalidations: AnyPublisher<Int, Never> { $generation.eraseToAnyPublisher() }
    var repairGeneration: Int { generation }
    var repairDirectory: URL { directory }
    private let reserve: Int64 = 1_000_000_000
    var capacity: Int64 {
        let selected = UserDefaults.standard.object(forKey: "cacheLimitGB") as? Int ?? 5
        return Int64([1, 5, 10, 20].contains(selected) ? selected : 5) * 1_000_000_000
    }
    private var availableBytes: Int64? {
        if let availableBytesProvider { return availableBytesProvider() }
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
    }

    init(directoryURL: URL? = nil, monitorNetwork: Bool = true, diagnostics: LocalDiagnosticsStore? = .shared,
         availableBytesProvider: (() -> Int64?)? = nil) {
        directory = directoryURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CivitMedia", isDirectory: true)
        self.diagnostics = diagnostics
        self.availableBytesProvider = availableBytesProvider
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var folder = directory; try? folder.setResourceValues(values)
        memory.totalCostLimit = 64 * 1024 * 1024
        monitor.pathUpdateHandler = { [weak self] path in
            let allowed = path.status == .satisfied && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)) && !path.isExpensive && !path.isConstrained
            Task { @MainActor in self?.unmetered = allowed }
        }
        if monitorNetwork { monitor.start(queue: DispatchQueue(label: "CivitViewer.network")) }
        trim()
    }

    private func key(_ url: URL, video: Bool) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() + (video ? ".mp4" : ".img")
    }

    func cached(_ url: URL, video: Bool) -> URL? {
        let target = directory.appendingPathComponent(key(url, video: video))
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
        cacheHits += 1
        return target
    }

    func pin(_ url: URL) { pinned[key(url, video: true), default: 0] += 1 }
    func unpin(_ url: URL) {
        let name = key(url, video: true)
        if let count = pinned[name], count > 1 { pinned[name] = count - 1 } else { pinned[name] = nil }
    }
    func protectRepairFile(_ file: URL) {
        guard file.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return }
        repairPins[file.lastPathComponent, default: 0] += 1
    }
    func unprotectRepairFile(_ file: URL) {
        let name = file.lastPathComponent
        if let count = repairPins[name], count > 1 { repairPins[name] = count - 1 } else { repairPins[name] = nil }
    }
    private func protected(_ name: String) -> Bool { pinned[name] != nil || repairPins[name] != nil }
    func reserveRepairBudget() -> Int64 {
        let requested = min(536_870_912, max(0, capacity / 2))
        repairReserved += requested
        trim()
        guard diskUsageKnown else { repairReserved -= requested; return 0 }
        let budget = min(requested, max(0, capacity - diskBytes - (repairReserved - requested)), max(0, (availableBytes ?? reserve) - reserve - downloadReserved))
        repairReserved -= requested - budget
        return budget
    }
    func releaseRepairBudget(_ bytes: Int64) { repairReserved = max(0, repairReserved - bytes); trim() }
    func repairOriginal(_ url: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        try await fetchFile(url, video: true, videoMaximum: 536_870_912, progress: progress)
    }
    func discardBrokenVideo(_ address: URL, expected: MediaRepairStore.Identity) {
        let file = directory.appendingPathComponent(key(address, video: true))
        guard MediaRepairStore.identity(file) == expected else { return }
        try? FileManager.default.removeItem(at: file)
    }

    func image(_ url: URL) async -> UIImage? {
        try? await loadImage(url)
    }

    func loadImage(_ url: URL) async throws -> UIImage {
        try Task.checkCancellation()
        if url.isFileURL {
            guard FileManager.default.fileExists(atPath: url.path) else { throw ImageLoadError.missingLocal }
            let decoded = await Task.detached(priority: .userInitiated) { Self.downsample(url) }.value
            try Task.checkCancellation()
            guard let decoded else {
                if Self.isKnownErrorDocument(url) { throw MediaDownloadError.notImage }
                if MediaImageDecoder.looksLikeVideo(url) { throw MediaDownloadError.videoContent }
                throw ImageLoadError.decode
            }; return decoded
        }
        let requestGeneration = generation
        let knownVideo = directory.appendingPathComponent(key(url, video: true))
        if FileManager.default.fileExists(atPath: knownVideo.path), MediaImageDecoder.looksLikeVideo(knownVideo) {
            throw MediaDownloadError.videoContent
        }
        if let value = memory.object(forKey: url as NSURL) {
            cacheHits += 1
            let target = directory.appendingPathComponent(key(url, video: false))
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
            return value
        }
        // Old versions could cache a successful HTTP body that wasn't an image.
        // Evict only that exact cache entry; never touch offline-library files.
        if let existing = cached(url, video: false) {
            let identity = (try? FileManager.default.attributesOfItem(atPath: existing.path)[.systemFileNumber]) as? NSNumber
            let decoded = await Task.detached(priority: .userInitiated) { Self.downsample(existing) }.value
            try Task.checkCancellation()
            guard requestGeneration == generation else { throw CancellationError() }
            if let decoded { remember(decoded, url: url); return decoded }
            let current = (try? FileManager.default.attributesOfItem(atPath: existing.path)[.systemFileNumber]) as? NSNumber
            if identity != nil && identity == current { try? FileManager.default.removeItem(at: existing) }
        }
        let file = try await fetchFile(url, video: false)
        try Task.checkCancellation()
        let decoded = await Task.detached(priority: .userInitiated) { Self.downsample(file) }.value
        try Task.checkCancellation()
        guard requestGeneration == generation else { throw CancellationError() }
        guard let image = decoded else { throw ImageLoadError.decode }
        remember(image, url: url)
        return image
    }
    func imageResource(_ url: URL) async throws -> CachedImageResource {
        let preview = try await loadImage(url)
        var file = url.isFileURL ? url : directory.appendingPathComponent(key(url, video: false))
        if !FileManager.default.fileExists(atPath: file.path) {
            memory.removeObject(forKey: url as NSURL)
            file = try await fetchFile(url, video: false)
        }
        let info = await Task.detached(priority: .userInitiated) { MediaImageDecoder.info(file) }.value
        try Task.checkCancellation()
        guard let info else { throw ImageLoadError.decode }
        return CachedImageResource(file: file, preview: preview, frameCount: info.frameCount)
    }
    private func posterTarget(_ source: URL) -> URL {
        let name = SHA256.hash(data: Data((source.absoluteString + "#first-frame.v1").utf8)).map { String(format: "%02x", $0) }.joined() + ".jpg"
        return directory.appendingPathComponent(name)
    }
    func posterCacheKey(for source: URL) -> String { posterTarget(source).lastPathComponent }
    private func publishRetainedPoster(_ target: URL) {
        // A low-space trim can evict a newly written poster immediately. Such a
        // write must not restart its own extractor through a cache-miss loop.
        guard Self.downsample(target) != nil else { return }
        posterWrites.send(target.lastPathComponent)
    }
    func hasGeneratedPoster(_ source: URL) -> Bool { Self.downsample(posterTarget(source)) != nil }
    func storeGeneratedPoster(_ data: Data, source: URL, expectedGeneration: Int) throws {
        try Task.checkCancellation()
        guard expectedGeneration == generation else { throw CancellationError() }
        guard !source.isFileURL || FileManager.default.fileExists(atPath: source.path) else { throw ImageLoadError.missingLocal }
        guard data.count > 0, data.count <= 1_048_576,
              let image = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(image) as String? == "public.jpeg",
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...512).contains(width), (1...512).contains(height) else { throw ImageLoadError.decode }
        let amount = Int64(data.count)
        let target = posterTarget(source)
        var written = false
        repairReserved += amount
        defer {
            repairReserved -= amount; trim()
            if written, expectedGeneration == generation { publishRetainedPoster(target) }
        }
        trim()
        guard diskUsageKnown, diskBytes + repairReserved <= capacity,
              availableBytes.map({ $0 >= reserve + amount }) ?? false else { throw ImageLoadError.lowSpace }
        guard expectedGeneration == generation else { throw CancellationError() }
        try data.write(to: target, options: .atomic)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
        written = true
    }
    func loadPoster(source: URL, declared: URL?, allowExtraction: Bool, allowLocalExtraction: Bool = false,
                    onStage: ((PosterDiagnosticStage) -> Void)? = nil) async throws -> UIImage {
        onStage?(.cachedPoster)
        let target = posterTarget(source)
        if let image = Self.downsample(target) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
            return image
        }
        if let declared {
            onStage?(.declaredImage)
            do { return try await loadImage(declared) }
            catch MediaDownloadError.videoContent { /* Fall through to a still of this same asset. */ }
            catch MediaDownloadError.http(let code) where [404, 410].contains(code) { }
            catch ImageLoadError.decode where allowLocalExtraction {
                return try await recoverLocalPosterAfterDecode(source: source, failedStage: .declaredImage, onStage: onStage)
            }
            // Access/network/HTML/decode failures stay visible and retryable.
            // Do not switch URLs after 401/403 or a login/error page.
        }
        let still = MediaPosterPolicy.stillURL(declared ?? source)
        if let still, still != declared {
            onStage?(.staticVariant)
            do { return try await loadImage(still) }
            catch MediaDownloadError.videoContent { }
            catch MediaDownloadError.http(let code) where [404, 410].contains(code) { }
            catch ImageLoadError.decode where allowLocalExtraction {
                return try await recoverLocalPosterAfterDecode(source: source, failedStage: .staticVariant, onStage: onStage)
            }
        }
        onStage?(.localLookup)
        guard allowExtraction || allowLocalExtraction else { throw MediaDownloadError.videoContent }
        return try await extractPoster(source: source, allowDownload: allowExtraction, onStage: onStage)
    }

    /// A broken image can still use this work's already-local video. Preserve
    /// the image error if no usable local frame exists; never switch URLs or
    /// start a video download in response to an image decode failure.
    private func recoverLocalPosterAfterDecode(source: URL, failedStage: PosterDiagnosticStage,
                                              onStage: ((PosterDiagnosticStage) -> Void)?) async throws -> UIImage {
        do { return try await extractPoster(source: source, allowDownload: false, onStage: onStage) }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            onStage?(failedStage)
            throw ImageLoadError.decode
        }
    }

    private func extractPoster(source: URL, allowDownload: Bool,
                               onStage: ((PosterDiagnosticStage) -> Void)?) async throws -> UIImage {
        onStage?(.localLookup)
        let target = posterTarget(source)
        let id = UUID(), requestGeneration = generation
        var written = false
        try await posterJobs.acquire(id)
        defer {
            posterJobs.release(id); trim()
            if written, requestGeneration == generation { publishRetainedPoster(target) }
        }
        try Task.checkCancellation()
        // A detail preview can use files already on disk without downloading or
        // converting a video. Use the exact repair receipt, never guess a URL.
        if !source.isFileURL { pin(source) }
        defer { if !source.isFileURL { unpin(source) } }
        let original = source.isFileURL ? source : cached(source, video: true)
        let scope = source.isFileURL ? source.deletingLastPathComponent() : directory
        let repaired = MediaRepairStore.cached(source, original: original, directory: scope)?.url
        let file: URL, temporary: Bool
        if let repaired { file = repaired; temporary = false }
        else if let original { file = original; temporary = false }
        else {
            guard allowDownload else { throw MediaDownloadError.videoContent }
            onStage?(.originalDownload)
            guard availableBytes.map({ $0 >= reserve + 8 * 1024 * 1024 }) ?? true else { throw ImageLoadError.lowSpace }
            let downloaded = try await BoundedDownload.fetch(source, maxBytes: 8 * 1024 * 1024)
            file = downloaded.appendingPathExtension("mp4")
            do { try FileManager.default.moveItem(at: downloaded, to: file) }
            catch { try? FileManager.default.removeItem(at: downloaded); throw error }
            temporary = true
        }
        defer { if temporary { try? FileManager.default.removeItem(at: file) } }
        protectRepairFile(file); defer { unprotectRepairFile(file) }
        let fileIdentity = MediaRepairStore.identity(file)
        onStage?(.localFrame)
        let image = try await Self.firstFrame(file)
        try Task.checkCancellation()
        guard generation == requestGeneration, fileIdentity != nil,
              MediaRepairStore.identity(file) == fileIdentity else { throw CancellationError() }
        guard let data = image.jpegData(compressionQuality: 0.85) else { throw ImageLoadError.decode }
        onStage?(.cacheWrite)
        try data.write(to: target, options: .atomic)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
        written = true
        return image
    }

    nonisolated private static func firstFrame(_ file: URL) async throws -> UIImage {
        let asset = AVURLAsset(url: file)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 512, height: 512)
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: UIImage.self) { tasks in
                tasks.addTask { let frame = try await generator.image(at: .zero); return UIImage(cgImage: frame.image) }
                tasks.addTask { try await Task.sleep(for: .seconds(8)); generator.cancelAllCGImageGeneration(); throw ImageLoadError.decode }
                defer { tasks.cancelAll() }
                guard let image = try await tasks.next() else { throw ImageLoadError.decode }; return image
            }
        } onCancel: { generator.cancelAllCGImageGeneration() }
    }
    private func remember(_ image: UIImage, url: URL) {
        memory.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
    }

    func fetch(_ url: URL, video: Bool) async -> URL? {
        do { return try await fetchFile(url, video: video) }
        catch is CancellationError { return nil }
        catch MediaDownloadError.http(let status) { diagnostics?.note(area: .cache, code: .http, httpStatus: status); return nil }
        catch { diagnostics?.note(area: .cache, code: .loadFailed); return nil }
    }
    /// Long-video preloading has its own bounded budget. Ordinary fetch keeps
    /// its64MiB contract; an admitted preload can use up to512MiB when it fits.
    func preloadFile(_ url: URL, video: Bool) async throws -> URL {
        try await fetchFile(url, video: video, videoMaximum: video ? 512 * 1024 * 1024 : 64 * 1024 * 1024, prefetching: true)
    }
    func recordPreloadFailure(_ error: Error) -> DiagnosticCode {
        let code: DiagnosticCode
        switch error {
        case MediaDownloadError.limitExceeded: code = .limit
        case MediaDownloadError.http: code = .http
        case ImageLoadError.lowSpace, ImageLoadError.cacheWrite: code = .storage
        case ImageLoadError.queueFull: code = .queueFull
        case ImageLoadError.decode: code = .decode
        default: code = (error as NSError).domain == NSURLErrorDomain ? .network : .loadFailed
        }
        let status: Int?
        if case MediaDownloadError.http(let value) = error { status = value } else { status = nil }
        diagnostics?.note(area: .cache, code: code, httpStatus: status)
        return code
    }
    func setPreloadStatus(_ value: MediaPreloadStatus, owner: UUID) {
        preloadStatusOwner = owner
        if preloadStatus != value { preloadStatus = value }
    }
    private func pausePreloadStatus(owner: UUID) {
        guard preloadStatusOwner == owner, var value = preloadStatus else { return }
        value.paused = true; value.running = 0
        if preloadStatus != value { preloadStatus = value }
    }
    private func preloadMaximum(video: Bool, requested: Int64) throws -> Int64 {
        if !diskUsageKnown { trim() }
        guard diskUsageKnown, let free = availableBytes else { throw ImageLoadError.cacheWrite }
        let names = Set(pinned.keys).union(repairPins.keys).union(upcoming.values.flatMap { $0 })
        var held: Int64 = 0
        for name in names {
            let file = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            guard let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw ImageLoadError.cacheWrite }
            held += Int64(bytes)
        }
        let physical = max(0, free - reserve - repairReserved - downloadReserved)
        let foregroundHeadroom = min(128 * 1024 * 1024, capacity / 4)
        let quota = max(0, capacity - foregroundHeadroom - held - repairReserved - downloadReserved)
        let maximum = min(requested, physical, quota)
        guard maximum >= min(requested, video ? 8 * 1024 * 1024 : 1024 * 1024) else { throw ImageLoadError.lowSpace }
        return maximum
    }
    private func fetchFile(_ url: URL, video: Bool, videoMaximum: Int64 = 64 * 1024 * 1024,
                           progress: (@Sendable (Int64, Int64) -> Void)? = nil, prefetching: Bool = false,
                           allowQuotaUpgrade: Bool = true) async throws -> URL {
        try Task.checkCancellation()
        if url.isFileURL {
            guard FileManager.default.fileExists(atPath: url.path) else { throw ImageLoadError.missingLocal }; return url
        }
        if video, let file = cached(url, video: true) { return file }
        if video && url.pathExtension.lowercased() == "m3u8" { throw ImageLoadError.decode }
        let downloadKey = key(url, video: video), consumer = UUID()
        let requestGeneration = generation
        let flightID: UUID, task: Task<URL, Error>, inheritedMaximum: Int64
        if var flight = inFlight[downloadKey] {
            flight.consumers.insert(consumer); inFlight[downloadKey] = flight; flightID = flight.id; task = flight.task
            inheritedMaximum = flight.maximum
        } else {
            let id = UUID(), target = directory.appendingPathComponent(downloadKey)
            flightID = id
            inheritedMaximum = video ? videoMaximum : 16 * 1024 * 1024
            task = Task<URL, Error> {
                try await downloads.acquire(id)
                defer { downloads.release(id) }
                try Task.checkCancellation()
                // Reserve once per admitted flight, not once per consumer or
                // queued thumbnail. Concurrent preloads share the same budget.
                let requestedMaximum = video ? videoMaximum : 16 * 1024 * 1024
                let effectiveMaximum: Int64
                if prefetching {
                    do { effectiveMaximum = try preloadMaximum(video: video, requested: requestedMaximum) }
                    catch ImageLoadError.lowSpace { throw PreloadQuotaFailure(maximum: 0) }
                } else { effectiveMaximum = requestedMaximum }
                let reservation: Int64 = prefetching ? effectiveMaximum : (video ? min(videoMaximum, 64 * 1024 * 1024) : 16 * 1024 * 1024)
                let minimumFree = reserve + repairReserved + downloadReserved + reservation
                if let available = availableBytes, available < minimumFree {
                    trim()
                    if let afterTrim = availableBytes, afterTrim < minimumFree { throw ImageLoadError.lowSpace }
                }
                downloadReserved += reservation
                defer { downloadReserved -= reservation }
                if var flight = inFlight[downloadKey], flight.id == id {
                    flight.maximum = effectiveMaximum; inFlight[downloadKey] = flight
                }
                let file: URL
                do {
                    file = try await BoundedDownload.fetch(url, maxBytes: effectiveMaximum,
                        reserveBytes: videoMaximum > 64 * 1024 * 1024 ? reserve : 0,
                        expectedImage: !video, progress: progress)
                } catch MediaDownloadError.limitExceeded where prefetching && effectiveMaximum < requestedMaximum {
                    throw PreloadQuotaFailure(maximum: effectiveMaximum)
                }
                defer { try? FileManager.default.removeItem(at: file) }
                try Task.checkCancellation()
                guard requestGeneration == generation else { throw CancellationError() }
                if !video {
                    let valid = await Task.detached(priority: .userInitiated) { Self.downsample(file) != nil }.value
                    try Task.checkCancellation()
                    guard valid else {
                        if Self.isKnownErrorDocument(file) { throw MediaDownloadError.notImage }
                        if MediaImageDecoder.looksLikeVideo(file) {
                            let probe = file.appendingPathExtension("mp4")
                            try FileManager.default.moveItem(at: file, to: probe)
                            defer { try? FileManager.default.removeItem(at: probe) }
                            guard (try? await AVURLAsset(url: probe).load(.isPlayable)) == true else { throw ImageLoadError.decode }
                            try Task.checkCancellation()
                            guard requestGeneration == generation else { throw CancellationError() }
                            let videoTarget = directory.appendingPathComponent(key(url, video: true))
                            try? FileManager.default.removeItem(at: videoTarget)
                            try FileManager.default.moveItem(at: probe, to: videoTarget)
                            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: videoTarget.path)
                            throw MediaDownloadError.videoContent
                        }
                        throw ImageLoadError.decode
                    }
                }
                guard requestGeneration == generation else { throw CancellationError() }
                do {
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: file, to: target)
                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
                    return target
                } catch { throw ImageLoadError.cacheWrite }
            }
            inFlight[downloadKey] = .init(id: id, task: task, maximum: inheritedMaximum, consumers: [consumer])
        }
        defer { leave(downloadKey, flightID: flightID, consumer: consumer); trim() }
        do {
            return try await withTaskCancellationHandler {
                let result = try await task.value; try Task.checkCancellation()
                if video, let size = (try? result.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, Int64(size) > videoMaximum {
                    throw MediaDownloadError.limitExceeded
                }
                return result
            } onCancel: { Task { @MainActor in self.leave(downloadKey, flightID: flightID, consumer: consumer) } }
        } catch let quota as PreloadQuotaFailure {
            try Task.checkCancellation()
            guard requestGeneration == generation else { throw CancellationError() }
            guard !prefetching else { throw ImageLoadError.lowSpace }
            let ownMaximum: Int64 = video ? videoMaximum : 16 * 1024 * 1024
            guard ownMaximum > quota.maximum else { throw MediaDownloadError.limitExceeded }
            guard allowQuotaUpgrade else { throw ImageLoadError.lowSpace }
            // The quota-limited writer has ended. A foreground consumer may
            // re-admit once under its own contract, never with two URL writers.
            if inFlight[downloadKey]?.id == flightID { inFlight[downloadKey] = nil }
            return try await fetchFile(url, video: video, videoMaximum: videoMaximum, progress: progress,
                prefetching: false, allowQuotaUpgrade: false)
        } catch MediaDownloadError.limitExceeded where video && videoMaximum > inheritedMaximum {
            try Task.checkCancellation()
            guard requestGeneration == generation else { throw CancellationError() }
            // The smaller shared task has finished. Its existing consumers keep
            // that result; admit exactly one new, larger task to the same target.
            if inFlight[downloadKey]?.id == flightID { inFlight[downloadKey] = nil }
            return try await fetchFile(url, video: true, videoMaximum: videoMaximum, progress: progress,
                prefetching: prefetching, allowQuotaUpgrade: allowQuotaUpgrade)
        }
    }
    private func leave(_ key: String, flightID: UUID, consumer: UUID) {
        guard var flight = inFlight[key], flight.id == flightID else { return }
        flight.consumers.remove(consumer)
        if flight.consumers.isEmpty { flight.task.cancel(); inFlight[key] = nil }
        else { inFlight[key] = flight }
    }

    func setPrefetchTargets(_ targets: [(URL, Bool)], owner: UUID) {
        // Each visible viewer owns its bounded window. A departing viewer must
        // never replace or release another timeline's cache protection.
        upcoming[owner] = Set(targets.prefix(24).filter { !$0.0.isFileURL }.map { key($0.0, video: $0.1) })
    }
    func removePrefetchTargets(owner: UUID) {
        pausePreloadStatus(owner: owner)
        guard upcoming.removeValue(forKey: owner) != nil else { return }
        trim()
    }
    func hasPrefetchSpace(video: Bool = true) -> Bool {
        (try? preloadMaximum(video: video, requested: video ? 512 * 1024 * 1024 : 16 * 1024 * 1024)) != nil
    }

    func clear() {
        preloadStatus = nil; preloadStatusOwner = nil
        generation += 1
        for flight in inFlight.values { flight.task.cancel() }; inFlight = [:]
        upcoming = [:]
        memory.removeAllObjects()
        for file in files() where !protected(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
        trim()
        cacheHits = 0
    }

    /// Inspect only a bounded prefix on a failed image decode. An HTML/JSON
    /// response remains a document error, even if its Content-Type says image.
    nonisolated private static func isKnownErrorDocument(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return false }
        var text = String(decoding: data, as: UTF8.self)
        if text.unicodeScalars.first?.value == 0xfeff { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // A failed raster decode beginning with markup is a document as well,
        // including HTML comments before a doctype or an omitted html root.
        return text.hasPrefix("{") || text.hasPrefix("[") || text.hasPrefix("<")
    }

    nonisolated private static func downsample(_ file: URL) -> UIImage? {
        guard let image = MediaImageDecoder.preview(file) else { return nil }
        return UIImage(cgImage: image)
    }

    private func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
    }

    func trim() {
        guard let listed = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            diskUsageKnown = false
            return
        }
        let entries = listed.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize else { return nil }
            return (url, Int64(size), values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        guard entries.count == listed.count else { diskUsageKnown = false; return }
        var bytes = entries.reduce(Int64(0)) { $0 + $1.1 }
        let budget = min(max(0, capacity - repairReserved), max(0, bytes + (availableBytes ?? reserve) - reserve))
        let prefetched = upcoming.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        for (file, size, _) in entries where bytes > budget && !protected(file.lastPathComponent) && !prefetched.contains(file.lastPathComponent) {
            if (try? FileManager.default.removeItem(at: file)) != nil { bytes -= size }
        }
        diskBytes = bytes
        diskUsageKnown = true
    }
}

/// Stop oversized downloads while in progress; never load a whole video into RAM.
enum MediaDownloadError: LocalizedError {
    case limitExceeded, http(Int), notImage, videoContent
    var errorDescription: String? {
        switch self {
        case .limitExceeded: "文件超过下载限制"
        case .http(let code): [404, 410].contains(code) ? "封面地址暂不可用" : (code == 429 ? "请求较多，请稍后重试" : "网络请求失败（\(code)）")
        case .notImage: "站点返回的封面不是图片"
        case .videoContent: "此地址是视频，正在切换播放"
        }
    }
}

final class BoundedDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let maxBytes: Int64
    private let reserveBytes: Int64
    private let expectedImage: Bool
    private let progress: (@Sendable (Int64, Int64) -> Void)?
    private let lock = NSLock()
    private var cancelled = false
    private var activeTask: URLSessionDownloadTask?
    private var limited = false
    private var spaceLimited = false
    private var lastSpaceCheck = Date.distantPast
    private var lastProgress = Date.distantPast
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    private var session: URLSession?

    private init(maxBytes: Int64, reserveBytes: Int64, expectedImage: Bool, progress: (@Sendable (Int64, Int64) -> Void)?) {
        self.maxBytes = maxBytes; self.reserveBytes = reserveBytes; self.expectedImage = expectedImage; self.progress = progress
    }
    static func fetch(_ url: URL, maxBytes: Int64, reserveBytes: Int64 = 0, expectedImage: Bool = false,
                      progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> URL {
        let downloader = BoundedDownload(maxBytes: maxBytes, reserveBytes: reserveBytes, expectedImage: expectedImage, progress: progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { downloader.begin(url, continuation: $0) }
        } onCancel: { downloader.cancel() }
    }
    private func begin(_ url: URL, continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = reserveBytes > 0 ? 600 : 90
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        let task = session.downloadTask(with: url); activeTask = task
        lock.unlock(); task.resume()
    }
    private func cancel() {
        lock.lock(); cancelled = true; let task = activeTask; lock.unlock()
        task?.cancel()
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maxBytes || totalBytesExpectedToWrite > maxBytes { limited = true; downloadTask.cancel(); return }
        if reserveBytes > 0 && Date().timeIntervalSince(lastSpaceCheck) > 1 {
            lastSpaceCheck = Date()
            let space = try? FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            if let free = space?.volumeAvailableCapacity, Int64(free) < reserveBytes { spaceLimited = true; downloadTask.cancel(); return }
        }
        if Date().timeIntervalSince(lastProgress) > 0.2 || totalBytesWritten == totalBytesExpectedToWrite {
            lastProgress = Date(); progress?(totalBytesWritten, totalBytesExpectedToWrite)
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let response = downloadTask.response as? HTTPURLResponse, response.statusCode != 200 {
            result = .failure(MediaDownloadError.http(response.statusCode)); return
        }
        guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
              expectedImage || response.mimeType.map({ $0.hasPrefix("image/") || $0.hasPrefix("video/") || $0 == "application/octet-stream" }) == true,
              let size = try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, Int64(size) <= maxBytes else {
            result = .failure(ClientError.invalidResponse); return
        }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do { try FileManager.default.moveItem(at: location, to: target); result = .success(target) }
        catch { result = .failure(error) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let userCancelled = cancelled; activeTask = nil; lock.unlock()
        if limited || spaceLimited || userCancelled || error != nil, case .success(let file) = result { try? FileManager.default.removeItem(at: file) }
        if userCancelled { continuation?.resume(throwing: CancellationError()) }
        else if spaceLimited { continuation?.resume(throwing: ImageLoadError.lowSpace) }
        else if limited { continuation?.resume(throwing: MediaDownloadError.limitExceeded) }
        else if let error { continuation?.resume(throwing: error) }
        else if let result { continuation?.resume(with: result) }
        else { continuation?.resume(throwing: ClientError.invalidResponse) }
        continuation = nil; session.finishTasksAndInvalidate(); self.session = nil
    }
}
