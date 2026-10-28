import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import ImageIO

/// A single frame from the existing native player, never a second asset reader.
/// The source buffer may be full resolution; only the rendered JPEG is <=512px.
final class VideoPosterPixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
    init(_ value: CVPixelBuffer) { self.value = value }
}

struct VideoPosterJPEG: Sendable {
    let data: Data
    let width: Int
    let height: Int
}

enum VideoPosterFrameError: Error, Equatable { case unsupported, render }

enum VideoPosterFrame {
    private final class Renderer: @unchecked Sendable {
        let context = CIContext(options: [.cacheIntermediates: false])
    }
    private static let renderer = Renderer()

    static func render(_ frame: VideoPosterPixelBuffer, preferredTransform: CGAffineTransform) throws -> VideoPosterJPEG {
        try Task.checkCancellation()
        let width = CVPixelBufferGetWidth(frame.value), height = CVPixelBufferGetHeight(frame.value)
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { throw VideoPosterFrameError.unsupported }
        let transfer = CVBufferCopyAttachment(frame.value, kCVImageBufferTransferFunctionKey, nil) as? String
        guard transfer != (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String),
              transfer != (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) else { throw VideoPosterFrameError.unsupported }
        let values = [preferredTransform.a, preferredTransform.b, preferredTransform.c, preferredTransform.d, preferredTransform.tx, preferredTransform.ty]
        guard values.allSatisfy(\.isFinite), abs(preferredTransform.a * preferredTransform.d - preferredTransform.b * preferredTransform.c) > 0.0001 else { throw VideoPosterFrameError.unsupported }

        // Container display transforms use a top-left coordinate system. Core
        // Image uses bottom-left; convert both bases, then normalize the extent.
        let display = CGRect(x: 0, y: 0, width: width, height: height).applying(preferredTransform)
        guard display.width.isFinite, display.height.isFinite, display.width > 0, display.height > 0,
              display.width <= 8192, display.height <= 8192 else { throw VideoPosterFrameError.unsupported }
        let fromCI = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(height))
        let toCI = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: display.height)
        let transform = fromCI.concatenating(preferredTransform)
            .concatenating(CGAffineTransform(translationX: -display.minX, y: -display.minY)).concatenating(toCI)
        var image = CIImage(cvPixelBuffer: frame.value).transformed(by: transform)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let scale = min(1, 512 / max(image.extent.width, image.extent.height))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let outWidth = max(1, min(512, Int(image.extent.width.rounded(.down))))
        let outHeight = max(1, min(512, Int(image.extent.height.rounded(.down))))
        guard let cg = renderer.context.createCGImage(image, from: CGRect(x: 0, y: 0, width: outWidth, height: outHeight),
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { throw VideoPosterFrameError.render }
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { throw VideoPosterFrameError.render }
        CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length > 0, data.length <= 1_048_576 else { throw VideoPosterFrameError.render }
        return .init(data: data as Data, width: outWidth, height: outHeight)
    }
}

/// One encoder and at most one waiting frame, independent of prefetch jobs.
@MainActor final class VideoPosterProcessor {
    static let shared = VideoPosterProcessor()
    private let queue = MediaLoadQueue(limit: 1, maximumWaiting: 1)
    func process(_ frame: VideoPosterPixelBuffer, item: AVPlayerItem) async throws -> VideoPosterJPEG {
        let id = UUID(); try await queue.acquire(id); defer { queue.release(id) }
        try Task.checkCancellation()
        let transform: CGAffineTransform
        if item.videoComposition != nil { transform = .identity }
        else {
            guard let track = try await item.asset.loadTracks(withMediaType: .video).first else { throw VideoPosterFrameError.unsupported }
            transform = try await track.load(.preferredTransform)
        }
        try Task.checkCancellation()
        let task = Task.detached(priority: .utility) { try VideoPosterFrame.render(frame, preferredTransform: transform) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
