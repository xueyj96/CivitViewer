import SwiftUI
import UIKit
import AVFoundation
import CryptoKit
import CivitMediaEngine

private final class ProbeResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCode: Int32 = -999
    private var storedExists = false
    private var storedFinished = false
    private var storedProgress: Double = -1
    func set(code: Int32, exists: Bool, progress: Double) { lock.lock(); storedCode = code; storedExists = exists; storedProgress = progress; storedFinished = true; lock.unlock() }
    func get() -> (Int32, Bool, Bool, Double) { lock.lock(); defer { lock.unlock() }; return (storedCode, storedExists, storedFinished, storedProgress) }
}

private final class ProbeJobHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    func cancel() { cvm_job_cancel(pointer) }
    deinit { cvm_job_destroy(pointer) }
}

private final class ProbeImageCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    func finish(_ continuation: CheckedContinuation<(Bool, Int), Never>, result: (Bool, Int)) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return }
        completed = true
        continuation.resume(returning: result)
    }
}

@MainActor
private final class MediaRepairEngineProbe: ObservableObject {
    @Published var player: AVPlayer?
    @Published var layerReady = false
    @Published var status = "Starting local media-engine probe"

    func run() async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let inputDirectory = Bundle.main.bundleURL.appendingPathComponent("fixtures", isDirectory: true)
        let outputDirectory = documents.appendingPathComponent("output", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        var report: [String: Any] = [
            "finished": false,
            "scope": "Synthetic local fixtures only; muted simulator playback; no network or user data",
            "engineVersion": String(cString: cvm_engine_version()),
            "results": [String: Any]()
        ]
        var results: [String: Any] = [:]

        func input(_ name: String) -> String { inputDirectory.appendingPathComponent(name).path }
        func output(_ name: String) -> String { outputDirectory.appendingPathComponent(name).path }
        func probe(_ path: String) -> [String: Any] {
            guard let job = cvm_job_create() else { return ["code": -999] }
            defer { cvm_job_destroy(job) }
            var info = CVMInfo()
            let code = path.withCString { cvm_probe(job, $0, &info) }
            return ["code": Int(code), "container": Int(info.container), "videoCodec": Int(info.video_codec),
                    "width": Int(info.width), "height": Int(info.height), "hasAudio": info.has_audio != 0,
                    "hdr": info.hdr != 0, "duration": info.duration, "frameRate": info.frame_rate]
        }
        func convert(_ source: String, _ destination: String, _ mode: Int32, _ limit: Int64 = 64 * 1024 * 1024) -> [String: Any] {
            guard let job = cvm_job_create() else { return ["code": -999] }
            defer { cvm_job_destroy(job) }
            let code = source.withCString { inputPath in
                destination.withCString { outputPath in cvm_convert(job, inputPath, outputPath, mode, limit) }
            }
            let exists = FileManager.default.fileExists(atPath: destination)
            let hash = exists ? sha256(destination) : nil
            let outputProbe = exists ? probe(destination) : [:]
            return ["code": Int(code), "outputExists": exists, "outputSHA256": hash.map { $0 as Any } ?? NSNull(),
                    "progress": cvm_job_progress(job), "outputProbe": outputProbe]
        }

        // Remux a known synthetic VP9 WebM without changing its codec.
        status = "Remuxing synthetic VP9"
        results["vp9Probe"] = probe(input("vp9.webm"))
        results["vp9Remux"] = convert(input("vp9.webm"), output("vp9-remux.mp4"), Int32(CVM_REMUX))

        // VP8 and Opus require H.264/AAC normalization for native playback.
        status = "Transcoding synthetic VP8"
        results["vp8Probe"] = probe(input("vp8.webm"))
        results["vp8Transcode"] = convert(input("vp8.webm"), output("vp8-h264.mp4"), Int32(CVM_TRANSCODE))
        status = "Transcoding synthetic Opus audio"
        results["opusProbe"] = probe(input("opus-vp8.webm"))
        results["opusTranscode"] = convert(input("opus-vp8.webm"), output("opus-h264-aac.mp4"), Int32(CVM_TRANSCODE))
        results["audioGapProbe"] = probe(input("audio-gap-vp8.webm"))
        results["audioGapTranscode"] = convert(input("audio-gap-vp8.webm"), output("audio-gap-partial.mp4"), Int32(CVM_TRANSCODE))

        // Preserve a 90 degree display matrix and source duration during an explicit H.264 transcode.
        status = "Checking display rotation and duration"
        results["rotatedProbe"] = probe(input("rotated-h264.mp4"))
        results["rotatedTranscode"] = convert(input("rotated-h264.mp4"), output("rotated-h264-copy.mp4"), Int32(CVM_TRANSCODE))

        status = "Checking invalid input, output safety, and cancellation"
        results["htmlReject"] = probe(input("not-video.html"))
        results["damagedReject"] = probe(input("damaged.webm"))

        // The destination is created only by this fixture setup and contains a sentinel.
        let sentinel = output("existing-output.mp4")
        let sentinelData = Data("probe-preserve-existing-output".utf8)
        try? sentinelData.write(to: URL(fileURLWithPath: sentinel), options: .atomic)
        results["overwriteReject"] = convert(input("vp9.webm"), sentinel, Int32(CVM_REMUX))
        results["overwriteSentinelPreserved"] = sha256(sentinel) == SHA256.hash(data: sentinelData).map { String(format: "%02x", $0) }.joined()

        results["outputLimit"] = convert(input("vp9.webm"), output("limited.mp4"), Int32(CVM_REMUX), 1024)

        if let job = cvm_job_create() {
            cvm_job_cancel(job)
            let code = input("vp9.webm").withCString { source in
                output("cancelled.mp4").withCString { destination in cvm_convert(job, source, destination, Int32(CVM_REMUX), 64 * 1024 * 1024) }
            }
            results["preCancelled"] = ["code": Int(code), "outputExists": FileManager.default.fileExists(atPath: output("cancelled.mp4"))]
            cvm_job_destroy(job)
        }

        // In-flight cancellation against a generated 8-second synthetic VP8 fixture.
        results["inflightCancellation"] = await cancelSyntheticTranscode(
            inputPath: input("cancel-vp8.webm"), outputPath: output("inflight-cancelled.mp4"))

        if ProcessInfo.processInfo.arguments.contains("--qa-cancel-only") {
            // Recreate only the synthetic VP9 remux and test the same first-frame
            // path used by the production repair service's image generator.
            try? FileManager.default.removeItem(atPath: output("vp9-remux.mp4"))
            let vp9Remux = convert(input("vp9.webm"), output("vp9-remux.mp4"), Int32(CVM_REMUX))
            results["vp9Remux"] = vp9Remux
            if (vp9Remux["code"] as? Int) == 0 {
                results["vp9ImageGenerator"] = await verifyImageGenerator(output("vp9-remux.mp4"))
            } else {
                results["vp9ImageGenerator"] = ["success": false, "errorCode": -999]
            }
            report["finished"] = (results["inflightCancellation"] as? [String: Any])?["finished"] as? Bool ?? false
            report["status"] = report["finished"] as? Bool == true ? "cancel-only-complete" : "cancel-only-incomplete"
            report["results"] = [
                "inflightCancellation": results["inflightCancellation"] ?? NSNull(),
                "vp9Remux": results["vp9Remux"] ?? NSNull(),
                "vp9ImageGenerator": results["vp9ImageGenerator"] ?? NSNull()
            ]
            write(report, to: documents.appendingPathComponent("results.json"))
            status = "Cancellation-only probe complete"
            return
        }

        // Native playback is checked for the remuxed VP9, converted VP8, and converted Opus outputs.
        status = "Verifying native first frame, playback, and seek"
        var playback: [String: Any] = [:]
        for (key, filename) in [("vp9", "vp9-remux.mp4"), ("vp8", "vp8-h264.mp4"), ("opus", "opus-h264-aac.mp4")] {
            playback[key] = await verifyPlayback(output(filename))
        }
        results["nativePlayback"] = playback
        results["outputHashes"] = [
            "vp9Remux": sha256(output("vp9-remux.mp4")).map { $0 as Any } ?? NSNull(),
            "vp8H264": sha256(output("vp8-h264.mp4")).map { $0 as Any } ?? NSNull(),
            "opusH264AAC": sha256(output("opus-h264-aac.mp4")).map { $0 as Any } ?? NSNull(),
            "rotatedH264": sha256(output("rotated-h264-copy.mp4")).map { $0 as Any } ?? NSNull()
        ]
        report["finished"] = true
        report["results"] = results
        report["status"] = "complete"
        write(report, to: documents.appendingPathComponent("results.json"))
        status = "Probe complete"
        player?.pause()
        player = nil
    }


    private func cancelSyntheticTranscode(inputPath: String, outputPath: String) async -> [String: Any] {
        guard let job = cvm_job_create() else { return ["code": -999, "finished": true, "outputExists": false] }
        let handle = ProbeJobHandle(job)
        let box = ProbeResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            let code = inputPath.withCString { source in
                outputPath.withCString { destination in cvm_convert(handle.pointer, source, destination, Int32(CVM_TRANSCODE), 64 * 1024 * 1024) }
            }
            let existsAfterReturn = FileManager.default.fileExists(atPath: outputPath)
            let progressAfterReturn = cvm_job_progress(handle.pointer)
            box.set(code: code, exists: existsAfterReturn, progress: progressAfterReturn)
        }
        try? await Task.sleep(for: .milliseconds(15))
        handle.cancel()
        var (code, exists, finished, progress) = box.get()
        for _ in 0..<2000 where !finished {
            try? await Task.sleep(for: .milliseconds(5))
            (code, exists, finished, progress) = box.get()
        }
        if !finished {
            // Do not touch or destroy the job while the worker may still use it.
            return ["code": Int(code), "finished": false, "outputExists": NSNull(), "progress": progress]
        }
        return ["code": Int(code), "finished": true, "outputExists": exists, "progress": progress]
    }

    private func verifyPlayback(_ path: String) async -> [String: Any] {
        guard FileManager.default.fileExists(atPath: path) else {
            return ["firstFrame": false, "advanced": false, "seekSucceeded": false, "muted": true, "missingOutput": true]
        }
        layerReady = false
        let current = AVPlayer(url: URL(fileURLWithPath: path))
        current.isMuted = true
        player = current
        current.play()
        var firstFrame = false
        var advanced = false
        for _ in 0..<80 {
            let time = current.currentTime().seconds
            if layerReady { firstFrame = true }
            if time.isFinite && time > 0.2 { advanced = true }
            if advanced && !firstFrame { current.pause() }
            if firstFrame && advanced { break }
            try? await Task.sleep(for: .milliseconds(75))
        }
        let beforeSeek = current.currentTime().seconds
        let itemError: Any = (current.currentItem?.error as NSError?).map { ["domain": $0.domain, "code": $0.code] as [String: Any] } ?? NSNull()
        let rateBeforeSeek = current.rate
        let seekSucceeded = await withCheckedContinuation { continuation in
            current.seek(to: CMTime(seconds: 0.6, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                continuation.resume(returning: finished)
            }
        }
        try? await Task.sleep(for: .milliseconds(75))
        let afterSeek = current.currentTime().seconds
        current.play()
        var advancedAfterSeek = false
        for _ in 0..<30 {
            if current.currentTime().seconds > 0.72 { advancedAfterSeek = true; break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        current.pause()
        let result: [String: Any] = ["firstFrame": firstFrame, "advanced": advanced,
            "beforeSeek": beforeSeek.isFinite ? beforeSeek : -1,
            "seekSucceeded": seekSucceeded, "afterSeek": afterSeek.isFinite ? afterSeek : -1,
            "advancedAfterSeek": advancedAfterSeek, "muted": current.isMuted,
            "itemStatus": current.currentItem?.status.rawValue ?? 0, "rateBeforeSeek": rateBeforeSeek, "itemError": itemError]
        return result
    }

    private func verifyImageGenerator(_ path: String) async -> [String: Any] {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let gate = ProbeImageCompletionGate()
        let result = await withCheckedContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: 0, preferredTimescale: 600))]) { _, image, _, result, error in
                let success = image != nil && result == .succeeded
                let code = success ? 0 : (error as NSError?)?.code ?? -999
                gate.finish(continuation, result: (success, code))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                generator.cancelAllCGImageGeneration()
                gate.finish(continuation, result: (false, -1001))
            }
        }
        generator.cancelAllCGImageGeneration()
        return ["success": result.0, "errorCode": result.1]
    }

    private func sha256(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func write(_ value: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

@MainActor
private struct ProbePlayerLayer: UIViewRepresentable {
    @ObservedObject var model: MediaRepairEngineProbe
    final class Host: UIView { override class var layerClass: AnyClass { AVPlayerLayer.self }; var videoLayer: AVPlayerLayer { layer as! AVPlayerLayer } }
    final class Coordinator { var observation: NSKeyValueObservation? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> Host {
        let view = Host(); view.backgroundColor = .black; view.videoLayer.videoGravity = .resizeAspect
        context.coordinator.observation = view.videoLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
            let ready = layer.isReadyForDisplay
            DispatchQueue.main.async { model.layerReady = ready }
        }
        view.videoLayer.player = model.player
        return view
    }
    func updateUIView(_ view: Host, context: Context) { view.videoLayer.player = model.player }
    static func dismantleUIView(_ view: Host, coordinator: Coordinator) { coordinator.observation = nil; view.videoLayer.player = nil }
}

@main
struct MediaRepairEngineProbeApp: App {
    @StateObject private var model = MediaRepairEngineProbe()
    var body: some Scene {
        WindowGroup {
            VStack {
                Text(model.status).font(.caption).foregroundStyle(.white)
                ProbePlayerLayer(model: model).frame(width: 320, height: 240)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .task { await model.run() }
        }
    }
}
