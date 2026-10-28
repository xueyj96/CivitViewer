import Foundation
import UIKit
import AVFoundation
import CivitMediaEngine

private final class MediaEngineJob: @unchecked Sendable {
    let pointer: OpaquePointer
    init() throws {
        guard let pointer = cvm_job_create() else { throw MediaRepairError.output }
        self.pointer = pointer
    }
    deinit { cvm_job_destroy(pointer) }
    func cancel() { cvm_job_cancel(pointer) }
}

private final class MediaRepairValidation: @unchecked Sendable {
    let asset: AVURLAsset
    let generator: AVAssetImageGenerator
    private let lock = NSLock()
    private var reader: AVAssetReader?
    private var cancelled = false
    init(_ file: URL) {
        asset = AVURLAsset(url: file)
        generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 160, height: 160)
    }
    func register(_ value: AVAssetReader) {
        lock.lock(); reader = value; let stopped = cancelled; lock.unlock()
        if stopped { value.cancelReading() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let value = reader; lock.unlock()
        value?.cancelReading(); generator.cancelAllCGImageGeneration(); asset.cancelLoading()
    }
}

/// All viewing entries use the same serial, on-demand repair pipeline. Merely
/// prefetching a video never starts a conversion. Cancellation retains originals.
@MainActor final class MediaRepair {
    static let shared = MediaRepair()
    private let queue = MediaLoadQueue(limit: 1, maximumWaiting: 2)
    private let cache: MediaCache
    private let offline: OfflineLibrary
    private let reserve: Int64 = 1_000_000_000
    init(cache: MediaCache? = nil, offline: OfflineLibrary? = nil) { self.cache = cache ?? .shared; self.offline = offline ?? .shared }

    struct Result { let url: URL; let transcoded: Bool; let reused: Bool }
    func cached(_ address: URL, offline isOffline: Bool) -> Result? {
        let original = address.isFileURL ? address : cache.cached(address, video: true)
        let directory = isOffline && address.isFileURL ? address.deletingLastPathComponent() : cache.repairDirectory
        guard let match = MediaRepairStore.cached(address, original: original, directory: directory) else { return nil }
        return .init(url: match.url, transcoded: match.transcoded, reused: true)
    }

    func repair(_ address: URL, offline isOffline: Bool, forceTranscode: Bool = false, diagnosticWorkID: Int? = nil,
                progress: @escaping (MediaRepairStage, Double?) -> Void) async throws -> Result {
        let id = UUID(); progress(.waiting, nil)
        try await queue.acquire(id); defer { queue.release(id) }
        try Task.checkCancellation()
        if !forceTranscode, let existing = cached(address, offline: isOffline) { return existing }
        if ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { throw MediaRepairError.paused }
        let cacheGeneration = cache.repairGeneration
        let scope = isOffline && address.isFileURL ? address.deletingLastPathComponent() : cache.repairDirectory
        let offlineScope = isOffline && address.isFileURL
        guard !offlineScope || offline.ownsRepairSource(address) else { throw MediaRepairError.unavailable }
        if !address.isFileURL { cache.pin(address) }
        defer { if !address.isFileURL { cache.unpin(address) }; cache.trim(); if offlineScope { offline.refreshRepairSizes() } }

        let original: URL
        if address.isFileURL { original = address }
        else {
            progress(.downloading, nil)
            original = try await cache.repairOriginal(address) { written, total in
                Task { @MainActor in progress(.downloading, total > 0 ? min(1, Double(written) / Double(total)) : nil) }
            }
        }
        let sourceIdentity = MediaRepairStore.identity(original)
        guard sourceIdentity != nil else { throw MediaRepairError.unavailable }
        func check() throws {
            try Task.checkCancellation()
            guard MediaRepairStore.identity(original) == sourceIdentity,
                  offlineScope ? offline.ownsRepairSource(address) : cache.repairGeneration == cacheGeneration else { throw CancellationError() }
        }
        try check(); progress(.inspecting, nil)
        let fingerprintTask = Task.detached(priority: .userInitiated) { try MediaRepairStore.contentHash(original) }
        let content = try await withTaskCancellationHandler { try await fingerprintTask.value } onCancel: { fingerprintTask.cancel() }
        try check()
        let info = try await runProbe(original)
        try check()
        let sourceKind: PlaybackDiagnosticSource = offlineScope ? .offline : (address.isFileURL ? .local : .cache)
        let started = PlaybackFailureDiagnostic(workID: diagnosticWorkID, source: sourceKind,
            requestedURL: address, sourceURL: original, recoveryAttempted: false, error: nil, eventStatusCodes: [],
            videoCodec: PlaybackVideoCodec(rawValue: Int(info.video_codec)) ?? .unknown)
        LocalDiagnosticsStore.shared.note(area: .playback, code: .repairStarted, playback: started)

        for transcode in forceTranscode ? [true] : [false, true] {
            try check()
            if transcode && info.hdr != 0 { throw MediaRepairError.hdr }
            let reservation = offlineScope ? offline.reserveRepairBudget() : cache.reserveRepairBudget()
            defer { if offlineScope { offline.releaseRepairBudget(reservation) } else { cache.releaseRepairBudget(reservation) } }
            guard offlineScope ? offline.diskUsageKnown : cache.diskUsageKnown else { throw MediaRepairError.storageUnknown }
            let limit = max(0, reservation - 4096) // Include the bounded receipt in the same quota.
            guard limit >= 8 * 1024 * 1024 else { throw MediaRepairError.lowSpace }
            let final = scope.appendingPathComponent(MediaRepairStore.outputName(address, content: content, transcoded: transcode))
            // A real MP4 still needs its container hint for native inspection.
            let partial = scope.appendingPathComponent(MediaRepairStore.stem(address) + "-" + UUID().uuidString + ".partial.mp4")
            if !offlineScope { cache.protectRepairFile(partial); cache.protectRepairFile(final) }
            defer {
                try? FileManager.default.removeItem(at: partial)
                if !offlineScope { cache.unprotectRepairFile(partial); cache.unprotectRepairFile(final) }
            }
            progress(transcode ? .transcoding : .remuxing, nil)
            do {
                try await convert(original: original, output: partial, transcode: transcode, limit: limit, check: check) { fraction in
                    progress(transcode ? .transcoding : .remuxing, fraction)
                }
                try check(); progress(.validating, nil)
                guard try await validate(partial, expected: info) else {
                    if transcode { throw MediaRepairError.validation }; continue
                }
                try check()
                // The destination belongs to this exact source content/profile.
                // An old failed derivative is replaceable; the original is not.
                if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.removeItem(at: final) }
                try FileManager.default.moveItem(at: partial, to: final)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: final.path)
                try MediaRepairStore.commit(address, original: original, content: content, transcoded: transcode, output: final, directory: scope)
                let completed = PlaybackFailureDiagnostic(workID: diagnosticWorkID, source: sourceKind,
                    requestedURL: address, sourceURL: final, recoveryAttempted: true, error: nil, eventStatusCodes: [],
                    repairMode: transcode ? .transcode : .remux,
                    videoCodec: transcode ? .h264 : (PlaybackVideoCodec(rawValue: Int(info.video_codec)) ?? .unknown))
                LocalDiagnosticsStore.shared.note(area: .playback, code: .repairCompleted, playback: completed)
                return .init(url: final, transcoded: transcode, reused: false)
            } catch is CancellationError { throw CancellationError() }
            catch MediaRepairError.lowSpace { throw MediaRepairError.lowSpace }
            catch MediaRepairError.paused { throw MediaRepairError.paused }
            catch MediaRepairError.expired { throw MediaRepairError.expired }
            catch { if transcode { throw error } }
        }
        throw MediaRepairError.validation
    }

    private func runProbe(_ file: URL) async throws -> CVMInfo {
        let job = try MediaEngineJob()
        var expired = false
        let timer = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(10)); expired = true; job.cancel() } catch { }
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            let pair = await Task.detached(priority: .userInitiated) {
                var info = CVMInfo()
                let code = cvm_probe(job.pointer, file.path, &info)
                return (code, info)
            }.value
            try Task.checkCancellation()
            if expired { throw MediaRepairError.expired }
            try Self.checkCode(pair.0)
            return pair.1
        } onCancel: { job.cancel() }
    }
    private func convert(original: URL, output: URL, transcode: Bool, limit: Int64,
                         check: @escaping () throws -> Void, progress: @escaping (Double?) -> Void) async throws {
        let job = try MediaEngineJob(), started = ContinuousClock.now
        var stopped: MediaRepairError?
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try check()
                    if ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { stopped = .paused; job.cancel(); return }
                    let free = try output.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
                    if let free, Int64(free) < reserve { stopped = .lowSpace; job.cancel(); return }
                    if ContinuousClock.now - started > .seconds(1200) { stopped = .expired; job.cancel(); return }
                    let fraction = cvm_job_progress(job.pointer)
                    progress(fraction >= 0 ? min(fraction, 0.99) : nil)
                    try await Task.sleep(for: .milliseconds(200))
                } catch { job.cancel(); return }
            }
        }
        defer { monitor.cancel() }
        let code = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                cvm_convert(job.pointer, original.path, output.path, Int32(transcode ? CVM_TRANSCODE : CVM_REMUX), limit)
            }.value
        } onCancel: { job.cancel() }
        if let stopped { throw stopped }
        try Task.checkCancellation(); try check(); try Self.checkCode(code)
    }
    private static func checkCode(_ code: Int32) throws {
        switch Int(code) {
        case CVM_OK: return
        case CVM_CANCELLED: throw CancellationError()
        case CVM_INPUT, CVM_DAMAGED, CVM_DECODE: throw MediaRepairError.damaged
        case CVM_UNSUPPORTED, CVM_TIMING: throw MediaRepairError.unsupported
        case CVM_HDR: throw MediaRepairError.hdr
        case CVM_LIMIT: throw MediaRepairError.lowSpace
        default: throw MediaRepairError.output
        }
    }
    private func validate(_ file: URL, expected: CVMInfo) async throws -> Bool {
        let state = MediaRepairValidation(file)
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask { try await Self.validate(state, expected: expected) }
                group.addTask {
                    try await Task.sleep(for: .seconds(10))
                    state.cancel(); throw MediaRepairError.validation
                }
                defer { group.cancelAll() }
                return try await group.next() ?? false
            }
        } onCancel: { state.cancel() }
    }
    nonisolated private static func validate(_ state: MediaRepairValidation, expected: CVMInfo) async throws -> Bool {
            let asset = state.asset
            guard try await asset.load(.isPlayable) else { return false }
            let video = try await asset.loadTracks(withMediaType: .video)
            guard !video.isEmpty else { return false }
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0,
                  expected.duration <= 0 || abs(duration - expected.duration) <= max(1, expected.duration * 0.02) else { return false }
            let audio = try await asset.loadTracks(withMediaType: .audio)
            guard (expected.has_audio != 0) == !audio.isEmpty else { return false }
            if let track = audio.first {
                let decodable = try await Task.detached(priority: .userInitiated) {
                    let reader = try AVAssetReader(asset: asset)
                    state.register(reader)
                    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
                    output.alwaysCopiesSampleData = false
                    guard reader.canAdd(output) else { return false }
                    reader.add(output)
                    guard reader.startReading() else { return false }
                    defer { reader.cancelReading() }
                    return output.copyNextSampleBuffer() != nil
                }.value
                guard decodable else { return false }
            }
            // Decode first frame; isPlayable alone is insufficient evidence.
            _ = try await state.generator.image(at: .zero)
            try Task.checkCancellation()
            return true
    }
}
