import Foundation

enum PlaybackDiagnosticSource: String, Codable, Hashable, Sendable {
    case network, cache, offline, local, unavailable
    var title: String {
        switch self { case .network: "网络"; case .cache: "浏览缓存"; case .offline: "离线收藏"; case .local: "本地文件"; case .unavailable: "来源尚未取得" }
    }
}

enum PlaybackDiagnosticExtension: String, Codable, Hashable, Sendable {
    case mp4, m4v, mov, webm, gif, webp, jpg, jpeg, png, m3u8, other
    init(url: URL) { self = Self(rawValue: url.pathExtension.lowercased()) ?? .other }
}

enum PlaybackDiagnosticEngine: String, Codable, Hashable, Sendable { case avFoundation, webKit }
enum PlaybackRepairMode: String, Codable, Hashable, Sendable { case remux, transcode }
enum PlaybackVideoCodec: Int, Codable, Hashable, Sendable { case unknown = 0, h264, hevc, vp9, vp8, mpeg4, mjpeg }
enum PosterDiagnosticStage: String, Codable, Hashable, Sendable {
    case cachedPoster, declaredImage, staticVariant, localLookup, originalDownload, localFrame, cacheWrite, decodedFrame
    case detailsVideo, detailsBitmap, detailsUnavailable
    case waitingForActivity, waitingForPlayer, waitingForOverlay, waitingForPlayback, waitingForPriorAttempt
}
enum PosterFailureKind: String, Codable, Hashable, Sendable {
    case queueFull, decode, lowSpace, missingLocal, cacheWrite, animationLimit
    case limitExceeded, http, notImage, videoContent, network, nativeFrame, unsupported, frameUnavailable, unknown
}

/// A bounded container hint from an already local file. Never opens a network URL.
enum PlaybackContainerHint: String, Codable, Hashable, Sendable {
    case isoBmff, ebml, gif, webp, html, json, unknown
    static func localFile(_ url: URL) -> Self? {
        guard url.isFileURL, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 64), !bytes.isEmpty else { return .unknown }
        if bytes.starts(with: [0x1a, 0x45, 0xdf, 0xa3]) { return .ebml }
        if bytes.count >= 12, String(data: bytes[4..<8], encoding: .ascii) == "ftyp" { return .isoBmff }
        if bytes.starts(with: Data("GIF87a".utf8)) || bytes.starts(with: Data("GIF89a".utf8)) { return .gif }
        if bytes.count >= 12, String(data: bytes.prefix(4), encoding: .ascii) == "RIFF",
           String(data: bytes[8..<12], encoding: .ascii) == "WEBP" { return .webp }
        let prefix = String(data: bytes.prefix(48), encoding: .utf8)?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html") { return .html }
        if prefix.hasPrefix("{") || prefix.hasPrefix("[") { return .json }
        return .unknown
    }
}

struct PlaybackNativeError: Codable, Equatable, Hashable, Sendable {
    enum Domain: String, Codable, Hashable, Sendable {
        case avFoundation = "AVFoundationErrorDomain"
        case urlLoading = "NSURLErrorDomain"
        case osStatus = "NSOSStatusErrorDomain"
        case coreMedia = "CoreMediaErrorDomain"
        case other
    }
    let domain: Domain
    let code: Int
}

/// Temporary, explicitly requested investigation of these public works only.
/// No URLs, account identifiers, descriptions, headers or media bytes are stored.
struct PlaybackFailureDiagnostic: Codable, Equatable, Hashable, Sendable {
    static let targetWorkID = 146_853_866
    static let currentTargetWorkID = 146_853_737
    static let posterTargetWorkID = 146_087_479
    static let targetWorkIDs: Set<Int> = [targetWorkID, currentTargetWorkID, posterTargetWorkID]
    let workID: Int
    let source: PlaybackDiagnosticSource
    let attempt: Int
    let requestedExtension: PlaybackDiagnosticExtension
    let sourceExtension: PlaybackDiagnosticExtension
    let localBytes: Int64?
    let nativeErrors: [PlaybackNativeError]
    let eventStatusCodes: [Int]
    let engine: PlaybackDiagnosticEngine?
    let containerHint: PlaybackContainerHint?
    let repairMode: PlaybackRepairMode?
    let videoCodec: PlaybackVideoCodec?
    let posterStage: PosterDiagnosticStage?
    let posterFailure: PosterFailureKind?

    init?(workID: Int?, source: PlaybackDiagnosticSource, requestedURL: URL, sourceURL: URL,
          recoveryAttempted: Bool, error: NSError?, eventStatusCodes: [Int], engine: PlaybackDiagnosticEngine = .avFoundation,
          repairMode: PlaybackRepairMode? = nil, videoCodec: PlaybackVideoCodec? = nil,
          posterStage: PosterDiagnosticStage? = nil, posterFailure: PosterFailureKind? = nil) {
        guard let workID, Self.targetWorkIDs.contains(workID) else { return nil }
        self.workID = workID; self.source = source; attempt = recoveryAttempted ? 1 : 0
        self.engine = engine
        self.repairMode = repairMode; self.videoCodec = videoCodec
        self.posterStage = posterStage; self.posterFailure = posterFailure
        containerHint = PlaybackContainerHint.localFile(sourceURL)
        requestedExtension = .init(url: requestedURL); sourceExtension = .init(url: sourceURL)
        if sourceURL.isFileURL,
           let size = (try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size]) as? NSNumber,
           size.int64Value >= 0 { localBytes = min(size.int64Value, 1_000_000_000_000) }
        else { localBytes = nil }
        var chain: [PlaybackNativeError] = []; var current = error
        for _ in 0..<5 {
            guard let value = current else { break }
            chain.append(.init(domain: PlaybackNativeError.Domain(rawValue: value.domain) ?? .other,
                               code: Self.safeCode(value.code)))
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        nativeErrors = chain
        self.eventStatusCodes = Array(eventStatusCodes.lazy.filter { $0 != 0 }.prefix(4)).map(Self.safeCode)
    }

    /// Route observation also covers rejected/missing URLs without inventing a
    /// request URL or recording the original string. Same three public IDs only.
    init?(workID: Int?, posterRoute: PosterDiagnosticStage, sourceURL: URL?, declaredURL: URL?) {
        guard let workID, Self.targetWorkIDs.contains(workID),
              [.detailsVideo, .detailsBitmap, .detailsUnavailable].contains(posterRoute) else { return nil }
        self.workID = workID; attempt = 0
        source = sourceURL.map { $0.isFileURL ? .local : .network } ?? .unavailable
        requestedExtension = (declaredURL ?? sourceURL).map(PlaybackDiagnosticExtension.init(url:)) ?? .other
        sourceExtension = sourceURL.map(PlaybackDiagnosticExtension.init(url:)) ?? .other
        localBytes = nil; nativeErrors = []; eventStatusCodes = []
        engine = nil; containerHint = nil; repairMode = nil; videoCodec = nil
        posterStage = posterRoute; posterFailure = nil
    }

    private static func safeCode(_ value: Int) -> Int { min(Int(Int32.max), max(Int(Int32.min), value)) }
    var isBounded: Bool {
        Self.targetWorkIDs.contains(workID) && (0...1).contains(attempt) && nativeErrors.count <= 5 && eventStatusCodes.count <= 4 &&
        nativeErrors.allSatisfy { $0.code == Self.safeCode($0.code) } && eventStatusCodes.allSatisfy { $0 == Self.safeCode($0) } &&
        (localBytes.map { (0...1_000_000_000_000).contains($0) } ?? true)
    }
    var summary: String {
        let native = nativeErrors.first.map { "\($0.domain.rawValue) \($0.code)" } ?? (engine == .webKit ? "媒体状态已记录" : "原生错误码未提供")
        let phase = engine == .webKit ? "兼容播放" : (attempt == 0 ? "首次" : "重试")
        return "作品 #\(workID) · \(source.title) · \(phase)\n\(native)"
    }
}
