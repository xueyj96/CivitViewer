import Foundation
import ImageIO
import CoreGraphics

/// Inspect bytes through ImageIO; extensions and HTTP Content-Type are advisory.
enum MediaImageDecoder {
    struct Info { let frameCount: Int; let type: String }
    struct Animation { let frames: [CGImage]; let duration: Double }

    static func info(_ file: URL) -> Info? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        return Info(frameCount: CGImageSourceGetCount(source), type: CGImageSourceGetType(source) as String? ?? "unknown")
    }
    static func preview(_ file: URL, pixels: Int = 2048) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return frame(source, index: 0, pixels: pixels)
    }
    private static func frame(_ source: CGImageSource, index: Int, pixels: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels
        ] as CFDictionary)
    }
    /// Only the focused viewer decodes animation. At most 32 x 384px frames
    /// (~18 MiB RGBA) and 400 metadata entries; no whole-resolution frame array.
    static func animation(_ file: URL) throws -> Animation {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw ImageLoadError.decode }
        let count = CGImageSourceGetCount(source)
        guard count > 1, count <= 400 else { throw ImageLoadError.animationLimit }
        var ends: [Double] = [], duration = 0.0
        for index in 0..<count {
            try Task.checkCancellation()
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
            let gif = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any]
            let webp = properties[kCGImagePropertyWebPDictionary as String] as? [String: Any]
            let png = properties[kCGImagePropertyPNGDictionary as String] as? [String: Any]
            let raw = (gif?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime as String] as? Double)
                ?? (webp?[kCGImagePropertyWebPUnclampedDelayTime as String] as? Double)
                ?? (webp?[kCGImagePropertyWebPDelayTime as String] as? Double)
                ?? (png?[kCGImagePropertyAPNGUnclampedDelayTime as String] as? Double)
                ?? (png?[kCGImagePropertyAPNGDelayTime as String] as? Double) ?? 0.1
            duration += raw.isFinite && raw > 0 ? max(0.02, min(raw, 10)) : 0.1
            ends.append(duration)
        }
        guard duration <= 120 else { throw ImageLoadError.animationLimit }
        let samples = min(32, max(2, count))
        var decoded: [Int: CGImage] = [:], frames: [CGImage] = []
        for sample in 0..<samples {
            try Task.checkCancellation()
            let time = Double(sample) * duration / Double(samples)
            let index = ends.firstIndex(where: { $0 > time }) ?? (count - 1)
            if decoded[index] == nil {
                guard let image = frame(source, index: index, pixels: 384) else { throw ImageLoadError.decode }
                decoded[index] = image
            }
            frames.append(decoded[index]!)
        }
        return Animation(frames: frames, duration: duration)
    }

    static func looksLikeVideo(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 64), bytes.count >= 12 else { return false }
        if bytes.starts(with: [0x1a, 0x45, 0xdf, 0xa3]) { return true } // EBML/WebM
        guard String(data: bytes[4..<8], encoding: .ascii) == "ftyp" else { return false }
        // HEIF/AVIF are images in the same ISO-BMFF container family.
        let brand = String(data: bytes[8..<12], encoding: .ascii) ?? ""
        return !["avif", "avis", "heic", "heix", "hevc", "hevx", "mif1", "msf1"].contains(brand)
    }
}

enum MediaPosterPolicy {
    /// Same documented public CDN asset, sized still variant. Never rewrite an
    /// unknown host, credentials, signed query, or an access-denied response.
    static func stillURL(_ source: URL) -> URL? {
        guard var url = URLComponents(url: source, resolvingAgainstBaseURL: false),
              url.scheme == "https", url.host?.lowercased() == "image.civitai.com",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        let parts = source.pathComponents.filter { $0 != "/" }
        guard let index = parts.firstIndex(where: { UUID(uuidString: $0) != nil }), index <= 2,
              parts.count == index + 2 || parts.count == index + 3 else { return nil }
        var preserved: [String] = []
        if parts.count == index + 3 {
            let pairs = parts[index + 1].split(separator: ",").map(String.init)
            guard pairs.count <= 24, pairs.allSatisfy({ $0.contains("=") }) else { return nil }
            // Retain blur/skip and all unrelated parameters; replace only the
            // delivery format/size switches that could select the original MP4.
            let replaced = Set(["width", "height", "anim", "transcode", "original", "optimized"])
            preserved = pairs.filter { !replaced.contains(String($0.split(separator: "=", maxSplits: 1)[0])) }
        }
        let params = preserved + ["width=450", "anim=false", "transcode=true", "original=false", "optimized=true"]
        url.path = "/" + (Array(parts.prefix(index + 1)) + [params.joined(separator: ","), "poster.jpeg"]).joined(separator: "/")
        return url.url
    }
}
