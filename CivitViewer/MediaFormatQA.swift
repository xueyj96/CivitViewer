#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import UIKit
import AVFoundation
import CryptoKit

/// Local synthetic patterns only. This route bypasses RootView, account refresh,
/// tag synchronization, history recording and offline-library downloads.
@MainActor enum MediaFormatQA {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--qa-media-format") }
    static var variant: String {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--qa-media-format"), i + 1 < args.count else { return "gif" }
        return args[i + 1]
    }
    static var root: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CivitMediaFormatQA") }
    static var item: MediaItem {
        let file: String
        switch variant {
        case "webp", "autoplay-off": file = "animated.webp"
        case "video-as-image", "poster": file = "short.mp4"
        case "static": file = "static.png"
        default: file = "animated.jpeg" // GIF bytes with deliberately misleading suffix.
        }
        var item = MediaItem(id: 900000028, url: "https://example.invalid/local-controlled-media", width: 192, height: 256,
                             type: variant == "gif-as-video" ? "video" : "image", username: "Controlled_Pattern", browsingLevel: 1,
                             thumbnail: nil, creatorID: 900000028, tags: [])
        item.offlineMediaURL = root.appendingPathComponent(file)
        return item
    }
    static func readback() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              let window = scene.windows.first(where: \.isKeyWindow) else { return }
        var bitmaps: [[String: Any]] = [], videos: [[String: Any]] = []
        func walk(_ view: UIView) {
            if let image = view as? UIImageView, image.accessibilityIdentifier == "bitmap-media" {
                bitmaps.append(["animating": image.isAnimating, "frames": image.animationImages?.count ?? 0,
                                "duration": image.animationDuration, "width": image.bounds.width, "height": image.bounds.height])
            }
            if let layer = view.layer as? AVPlayerLayer, let player = layer.player {
                videos.append(["readyForDisplay": layer.isReadyForDisplay, "rate": player.rate,
                               "position": player.currentTime().seconds.isFinite ? player.currentTime().seconds : -1,
                               "ready": player.currentItem?.status == .readyToPlay])
            }
            view.subviews.forEach(walk)
        }
        walk(window)
        let data: [String: Any] = ["build": Bundle.main.infoDictionary?["CFBundleVersion"] ?? "unknown", "case": variant,
                                   "bitmaps": bitmaps, "videos": videos, "autoplay": UserDefaults.standard.bool(forKey: "autoplay"),
                                   "source": "local synthetic color patterns; actual production MediaPageView"]
        if let bytes = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]) {
            try? bytes.write(to: root.appendingPathComponent("readback.json"), options: .atomic)
        }
    }
}

struct MediaFormatQAView: View {
    @State private var focused: Int? = 900000028
    @State private var active = true
    var body: some View {
        ZStack {
            if MediaFormatQA.variant == "poster" {
                CachedPoster(source: MediaFormatQA.item.mediaURL!, declared: MediaFormatQA.item.mediaURL!, active: true, fit: true)
            } else {
                MediaDeck(items: [MediaFormatQA.item], focused: $focused, isVisible: active, showsLoadMore: false, onAuthor: { _ in }, loadMore: {})
            }
        }.background(.black).preferredColorScheme(.dark)
            .task {
                UserDefaults.standard.set(MediaFormatQA.variant != "autoplay-off", forKey: "autoplay")
                for tick in 0..<50 {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    if MediaFormatQA.variant == "inactive" && tick == 18 { active = false }
                    MediaFormatQA.readback()
                }
            }
    }
}

@MainActor enum VisualControlsQA {
    static var enabled: Bool { CollectionPagingQA.enabled && ProcessInfo.processInfo.arguments.contains("--qa-visual-controls") }
    static var creatorID: Int { CollectionPagingQA.ownerID + 900 }
    static var state: String {
        ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--qa-control-state=") })?.components(separatedBy: "=").last ?? "normal"
    }
    static var width: CGFloat? {
        guard enabled, let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--qa-control-width=") }),
              let value = Double(argument.components(separatedBy: "=").last ?? ""), [320.0, 375, 440].contains(value) else { return nil }
        return CGFloat(value)
    }
    static var largeType: Bool { enabled && ProcessInfo.processInfo.arguments.contains("--qa-control-large-type") }
    static var author: String { ProcessInfo.processInfo.arguments.contains("--qa-control-long-author") ? "LongCreatorName_ForMediaControls_WithImagesAndVideos" : "LayoutCreator" }
}

/// Scripted local pages exercise the real Timeline/FeedStore/native pager path.
/// The observer counts fixture page reads, never site RPCs or user-account data.
@MainActor enum AutoContinuationQA {
    static var scenario: String? {
        guard CollectionPagingQA.enabled,
              let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--qa-auto-continuation=") }),
              let value = argument.components(separatedBy: "=").last,
              ["filtered-empty", "initial-empty", "rate-limited", "repeated-cursor", "sparse-reserve"].contains(value) else { return nil }
        return value
    }
    static var enabled: Bool { scenario != nil }
    static var filter: FeedFilter { FeedFilter(kind: .video, sort: "Newest", period: "AllTime") }
    @MainActor final class Observer: ObservableObject {
        @Published var requests = 0
        @Published var first = 0
        @Published var continuations = 0
        @Published var lastCursor = "none"
        @Published var returned = "none"
        @Published var errors = 0
        @Published var kind = "none"
        @Published var gate = "armed"
        @Published var gateReleased = false
        var prepared = false
        var limited = false
        var value: String { "scenario=\(AutoContinuationQA.scenario ?? "none");requests=\(requests);first=\(first);continuations=\(continuations);lastCursor=\(lastCursor);returned=\(returned);errors=\(errors);kind=\(kind);gate=\(gate)" }
    }
    static let shared = Observer()
    static func prepare() async throws {
        guard enabled, !shared.prepared else { return }
        let source = CollectionPagingQA.wideVideoEnabled
            ? CollectionPagingQA.root.appendingPathComponent("wide.mp4")
            : ResumePromptQA.videoFixtureURL
        guard source.isFileURL, FileManager.default.fileExists(atPath: source.path) else { throw ClientError.invalidResponse }
        let audio = try await AVURLAsset(url: source).loadTracks(withMediaType: .audio)
        guard audio.isEmpty else { throw ClientError.invalidResponse }
        if scenario == "sparse-reserve" {
            for item in CollectionPagingQA.sparseReserveItems {
                try CollectionPagingQA.seedVideoCache(source: source, item: item)
            }
        }
        shared.prepared = true
    }
    static func page(filter: FeedFilter, cursor: String?) async throws -> MediaPage {
        guard let scenario else { throw ClientError.invalidResponse }
        shared.requests += 1; shared.lastCursor = cursor ?? "none"; shared.kind = filter.effectiveKind.rawValue
        if cursor == nil { shared.first += 1 } else { shared.continuations += 1 }
        // Pause only the local transport response, after the real model has
        // entered loading. The QA button never calls a model or paging action.
        if cursor == "scan-0", ["filtered-empty", "initial-empty", "sparse-reserve", "rate-limited"].contains(scenario), !shared.gateReleased {
            shared.gate = "waiting"
            let deadline = ContinuousClock.now + .seconds(60)
            while !shared.gateReleased {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw ClientError.invalidResponse }
                try await Task.sleep(for: .milliseconds(50))
            }
            try Task.checkCancellation()
            shared.gate = "released"
        }
        // Preserve actual asynchronous loading/cooldown after gate release.
        try await Task.sleep(for: .milliseconds(cursor == nil ? 180 : 250))
        let fixture = CollectionPagingQA.items
        let page: MediaPage
        if scenario == "sparse-reserve" {
            let sparse = CollectionPagingQA.sparseReserveItems
            if cursor == nil {
                page = .init(items: [sparse[0]], metadata: .init(nextCursor: "scan-0"))
            } else {
                guard let cursor, cursor.hasPrefix("scan-"),
                      let index = Int(cursor.dropFirst(5)), (0...17).contains(index) else { throw ClientError.invalidResponse }
                let item = index % 3 == 2 ? sparse[index / 3 + 1] : fixture[0]
                page = .init(items: [item], metadata: .init(nextCursor: "scan-\(index + 1)"))
            }
        } else if cursor == nil {
            let firstItems = scenario == "initial-empty" ? [fixture[0]] : (scenario == "repeated-cursor" ? [fixture[2], fixture[4]] : [fixture[2]])
            page = .init(items: firstItems, metadata: .init(nextCursor: "scan-0"))
        } else if scenario == "rate-limited" {
            if !shared.limited { shared.limited = true; shared.errors += 1; throw ClientError.http(429) }
            page = .init(items: [fixture[4]], metadata: .init(nextCursor: nil))
        } else if scenario == "repeated-cursor" {
            page = .init(items: [fixture[0]], metadata: .init(nextCursor: cursor))
        } else {
            guard let cursor, cursor.hasPrefix("scan-"), let index = Int(cursor.dropFirst(5)), (0...8).contains(index) else { throw ClientError.invalidResponse }
            page = index < 8 ? .init(items: [fixture[0]], metadata: .init(nextCursor: "scan-\(index + 1)"))
                : .init(items: scenario == "initial-empty" ? [] : [fixture[4]], metadata: .init(nextCursor: nil))
        }
        shared.returned = page.items.map { String($0.id) }.joined(separator: ",")
        return page
    }
}

private struct AutoContinuationQAReadback: View {
    @ObservedObject private var state = AutoContinuationQA.shared
    var body: some View {
        HStack(spacing: 8) {
            Text(state.value).font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                .accessibilityIdentifier("continuation.qa.state").accessibilityValue(state.value)
            if ["filtered-empty", "initial-empty", "sparse-reserve", "rate-limited"].contains(AutoContinuationQA.scenario ?? "") {
                Button(state.gateReleased ? "本地响应已释放" : "释放本地响应") { state.gateReleased = true }
                    .accessibilityIdentifier("continuation.qa.release")
                    .disabled(state.gate != "waiting" || state.gateReleased)
                    .frame(minHeight: 44)
            }
        }.frame(maxWidth: .infinity, minHeight: 44).background(Color(uiColor: .systemBackground))
    }
}

/// Exercises the production Settings -> Collections -> grid -> full-screen route.
/// Simulator-only synthetic files; no network authorization, sync or user-data reset.
@MainActor enum CollectionPagingQA {
    static var playbackDiagnosticMode: String? {
        let value = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--qa-playback-diagnostics43=") })?.components(separatedBy: "=").last
        return value.flatMap { ["valid", "invalid-offline", "bad-cache", "invalid-untargeted", "invalid-current-target", "repair-vp9", "repair-vp8", "poster-stream49"].contains($0) ? $0 : nil }
    }
    static let enabled = ProcessInfo.processInfo.arguments.contains("--qa-collection-paging") ||
        ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--qa-auto-continuation=") }) ||
        ProcessInfo.processInfo.arguments.contains("--qa-details-tags") ||
        ProcessInfo.processInfo.arguments.contains("--qa-wide-video")
    static var wideVideoEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--qa-wide-video") }
    static var detailsTagsEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--qa-details-tags") }
    static let neutralDetailsTags: [MediaTag] = [
        .init(id: 42_001, name: "portrait"), .init(id: 42_002, name: "night"),
        .init(id: 42_003, name: "city"), .init(id: 42_004, name: "street fashion"),
        .init(id: 42_005, name: "soft lighting"), .init(id: 42_006, name: "cinematic"),
        .init(id: 42_007, name: "rain"), .init(id: 42_008, name: "architecture"),
        .init(id: 42_009, name: "neon signs"), .init(id: 42_010, name: "reflection"),
        .init(id: 42_011, name: "evening"), .init(id: 42_012, name: "long coat"),
        .init(id: 42_013, name: "urban landscape"), .init(id: 42_014, name: "depth of field"),
        .init(id: 42_015, name: "warm window light"), .init(id: 42_016, name: "35mm photo"),
        .init(id: 42_017, name: "blue hour"), .init(id: 42_018, name: "city walk")
    ]
    static let ownerID = 28_037_001
    private static let repairRun = UUID().uuidString
    private static let posterRun = UUID().uuidString
    static var posterStreamURL: URL { root.appendingPathComponent("stream49-" + posterRun + ".mp4") }
    static let collection = SavedCollection(id: 28_037_002, name: "分页测试收藏", userId: ownerID, type: "Image", mode: nil, read: "Private")
    static var biographyCase: String? {
        ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--qa-biography-case=") })?.components(separatedBy: "=").last
    }
    static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CivitCollectionPagingQA", isDirectory: true)
    }
    static var initialDurationFilter: FeedFilter {
        guard ProcessInfo.processInfo.arguments.contains("--qa-duration-legacy") else { return FeedFilter() }
        let legacy = Data(#"{"kind":"all","sort":"Most Reactions","period":"Week","baseModel":"","onlyPG":false,"videoDurationRange":{"minimumSeconds":120}}"#.utf8)
        return (try? JSONDecoder().decode(FeedFilter.self, from: legacy)) ?? FeedFilter()
    }
    static var items: [MediaItem] {
        if let mode = playbackDiagnosticMode {
            let workID = mode == "poster-stream49" ? PlaybackFailureDiagnostic.posterTargetWorkID : (mode == "invalid-untargeted" ? 146_853_867 :
                (mode == "invalid-current-target" ? PlaybackFailureDiagnostic.currentTargetWorkID : PlaybackFailureDiagnostic.targetWorkID)
            )
            let repair = mode.hasPrefix("repair-")
            var item = MediaItem(id: workID,
                                 url: repair ? "https://example.invalid/local-repair47/\(repairRun)/\(mode).mp4" : "",
                                 width: repair ? 320 : 480, height: repair ? 240 : 854, type: "video", username: "LocalPlaybackFixture",
                                 browsingLevel: 1, thumbnail: nil, creatorID: ownerID, tags: [])
            item.offlineMediaURL = mode == "invalid-offline" || mode == "invalid-untargeted" || mode == "invalid-current-target"
                ? root.appendingPathComponent("diagnostic-truncated.mp4") : ResumePromptQA.videoFixtureURL
            item.offlinePosterURL = root.appendingPathComponent("pattern-2.png")
            if repair { item.offlineMediaURL = nil }
            if mode == "poster-stream49" {
                item.offlineMediaURL = posterStreamURL
                item.offlinePosterURL = root.appendingPathComponent("unreadable49.jpeg")
            }
            return [item]
        }
        return (0..<6).map { index in
            let video = index == 2 || index == 4
            let wideVideo = video && wideVideoEnabled
            let tall = ViewportAuditQA.enabled && index != 1
            var item = MediaItem(id: 28_037_100 + index, url: "https://example.invalid/paging-\(index)",
                                 width: wideVideo ? 480 : (tall ? 192 : (video ? 320 : 192)),
                                 height: wideVideo ? 320 : (tall ? 416 : (video ? 180 : 256)),
                                 type: video ? "video" : "image", username: VisualControlsQA.enabled ? VisualControlsQA.author : (ViewportAuditQA.enabled ? "PagingFixture" : "PagingPattern_\(index)"), browsingLevel: 1, thumbnail: nil, creatorID: ownerID,
                                 tags: detailsTagsEnabled ? neutralDetailsTags : [])
            item.offlineMediaURL = wideVideo ? root.appendingPathComponent("wide.mp4") : (video ? ResumePromptQA.videoFixtureURL : root.appendingPathComponent("pattern-\(index).png"))
            if ViewportAuditQA.enabled && video { item.offlineMediaURL = ViewportAuditQA.root.appendingPathComponent("vertical.mp4") }
            // Exercise the real favorite button for a normal cached work, while
            // keeping every byte local and all site requests disabled in QA.
            if index == 0 && ProcessInfo.processInfo.arguments.contains("--qa-theme-ui") { item.offlineMediaURL = nil }
            if VisualControlsQA.enabled {
                item.offlineMediaURL = nil; item.creatorID = VisualControlsQA.creatorID
            }
            if wideVideo { item.offlineMediaURL = root.appendingPathComponent("wide.mp4") }
            if video { item.offlinePosterURL = root.appendingPathComponent("pattern-\(index).png") }
            if video { item.metadata = VideoTechnicalMetadata(duration: index == 2 ? 119.9 : 120.1) }
            return item
        }
    }
    /// Sparse scenario reuses fixture 2 as its focused first video and adds
    /// distinct URL identities backed by the same validated silent local file.
    static var sparseReserveItems: [MediaItem] {
        let first = items[2]
        let extras = (1...6).map { offset -> MediaItem in
            let id = 28_037_300 + offset
            var item = MediaItem(id: id, url: "https://example.invalid/sparse-reserve-\(offset).mp4",
                                 width: wideVideoEnabled ? 480 : 320, height: wideVideoEnabled ? 320 : 180,
                                 type: "video", username: "PagingPattern_\(id)", browsingLevel: 1,
                                 thumbnail: nil, creatorID: ownerID,
                                 tags: detailsTagsEnabled ? neutralDetailsTags : [])
            item.offlineMediaURL = nil // Resolve through the locally seeded CivitMedia cache.
            item.offlinePosterURL = root.appendingPathComponent("pattern-2.png")
            return item
        }
        var firstVideo = first
        firstVideo.offlineMediaURL = nil
        firstVideo.offlinePosterURL = root.appendingPathComponent("pattern-2.png")
        return [firstVideo] + extras
    }

    /// Seed the same URL-hash cache namespace used by MediaCache; never fetch
    /// fixture bytes from the example.invalid URL.
    static func seedVideoCache(source: URL, item: MediaItem) throws {
        guard source.isFileURL, FileManager.default.fileExists(atPath: source.path),
              let url = URL(string: item.url), url.scheme == "https", url.host == "example.invalid" else {
            throw ClientError.invalidResponse
        }
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CivitMedia", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        try Data(contentsOf: source).write(to: cache.appendingPathComponent(digest + ".mp4"), options: .atomic)
    }

    static func validateWideVideoIfRequested() async throws {
        guard wideVideoEnabled else { return }
        let file = root.appendingPathComponent("wide.mp4")
        guard file.isFileURL, FileManager.default.fileExists(atPath: file.path) else { throw ClientError.invalidResponse }
        let audio = try await AVURLAsset(url: file).loadTracks(withMediaType: .audio)
        guard audio.isEmpty else { throw ClientError.invalidResponse }
    }
    static func preparePlaybackDiagnosticsIfRequested() async throws {
        guard let mode = playbackDiagnosticMode else { return }
        if mode.hasPrefix("repair-") {
            let fixture = root.appendingPathComponent(mode + ".webm")
            guard MediaImageDecoder.looksLikeVideo(fixture), let item = items.first else { throw ClientError.invalidResponse }
            try seedVideoCache(source: fixture, item: item)
            try await LocalDiagnosticsStore.shared.clear()
            return
        }
        let original = ResumePromptQA.videoFixtureURL
        guard original.isFileURL, try await AVURLAsset(url: original).loadTracks(withMediaType: .audio).isEmpty else {
            throw ClientError.invalidResponse
        }
        let bytes = try Data(contentsOf: original)
        guard bytes.count > 1_024 && bytes.count < 64 * 1024 * 1024 else { throw ClientError.invalidResponse }
        if mode == "poster-stream49" {
            let latePoster = ProcessInfo.processInfo.arguments.contains("--qa-poster-late51")
            try (latePoster ? Data(bytes.prefix(1_024)) : bytes).write(to: posterStreamURL, options: .atomic)
            try Data("synthetic invalid poster body".utf8).write(to: root.appendingPathComponent("unreadable49.jpeg"), options: .atomic)
            try await LocalDiagnosticsStore.shared.clear()
            return
        }
        let broken = Data(bytes.prefix(1_024))
        try broken.write(to: root.appendingPathComponent("diagnostic-truncated.mp4"), options: .atomic)
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CivitMedia", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let key = SHA256.hash(data: Data(original.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() + ".mp4"
        let ownFixtureCache = cache.appendingPathComponent(key)
        if FileManager.default.fileExists(atPath: ownFixtureCache.path) { try FileManager.default.removeItem(at: ownFixtureCache) }
        if mode == "bad-cache" { try broken.write(to: ownFixtureCache, options: .atomic) }
        try await LocalDiagnosticsStore.shared.clear()
    }
    static func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let colors: [UIColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemCyan, .systemPink]
        for index in 0..<6 {
            let height: CGFloat = ViewportAuditQA.enabled && index != 1 ? 416 : 256
            let image = UIGraphicsImageRenderer(size: CGSize(width: 192, height: height)).image { context in
                colors[index].setFill(); context.fill(CGRect(x: 0, y: 0, width: 192, height: height))
                UIColor.white.setFill(); context.fill(CGRect(x: 16, y: 16, width: 160, height: 24))
            }
            try image.pngData()!.write(to: root.appendingPathComponent("pattern-\(index).png"), options: .atomic)
            if VisualControlsQA.enabled {
                let source = URL(string: "https://example.invalid/paging-\(index)")!
                let video = index == 2 || index == 4
                let name = SHA256.hash(data: Data(source.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() + (video ? ".mp4" : ".img")
                let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CivitMedia", isDirectory: true)
                try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                let data = video ? try Data(contentsOf: ResumePromptQA.videoFixtureURL) : image.pngData()!
                try data.write(to: cache.appendingPathComponent(name), options: .atomic)
            }
            if index == 0 && ProcessInfo.processInfo.arguments.contains("--qa-theme-ui") {
                let source = URL(string: "https://example.invalid/paging-0")!
                let name = SHA256.hash(data: Data(source.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() + ".img"
                let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CivitMedia", isDirectory: true)
                try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                try image.pngData()!.write(to: cache.appendingPathComponent(name), options: .atomic)
            }
        }
        // Audio is absent from the test video; mute is also enforced in the player.
        UserDefaults.standard.set(true, forKey: "muted")
        UserDefaults.standard.set(true, forKey: "autoplay")
    }
}

struct CollectionPagingQAView: View {
    @EnvironmentObject private var session: SiteSession
    @State private var ready = false
    @State private var latePosterWrite51 = "not-written"
    @State private var timelineTopRequest53 = 0
    @State private var timelineRestartRequest53 = 0
    @State private var selectedTab = ProcessInfo.processInfo.arguments.contains("--qa-theme-timeline") || VisualControlsQA.enabled || AutoContinuationQA.enabled || CollectionPagingQA.playbackDiagnosticMode != nil ? 0 : 3
    @State private var filter = CollectionPagingQA.initialDurationFilter
    private var biographyCase: String? {
        CollectionPagingQA.biographyCase
    }
    private var posterDetailsItem50: MediaItem {
        if ProcessInfo.processInfo.arguments.contains("--qa-image-failure55") {
            var value = MediaItem(id: 55_003, url: "", width: 192, height: 256, type: "image",
                                  username: "LocalFixture", browsingLevel: 8, thumbnail: nil, tags: [])
            value.offlineMediaURL = CollectionPagingQA.root.appendingPathComponent("missing-image55.png")
            return value
        }
        var item = CollectionPagingQA.items[0]
        if ProcessInfo.processInfo.arguments.contains("--qa-poster-missing50") { item.offlineMediaURL = nil }
        return item
    }
    var body: some View {
        Group {
            if ProcessInfo.processInfo.arguments.contains("--qa-duration-filter") {
                FilterView(filter: $filter).overlay(alignment: .topTrailing) {
                    Text(filter.videoDurationRange?.summary ?? "none").font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01)
                        .accessibilityIdentifier("duration.qa.state").accessibilityValue(filter.videoDurationRange?.summary ?? "none")
                }
            } else if ready && ProcessInfo.processInfo.arguments.contains("--qa-poster-details50") {
                MediaDetailsView(item: posterDetailsItem50)
            } else if let biographyCase, ready {
                NavigationStack {
                    CreatorView(creator: Creator(id: CollectionPagingQA.ownerID, username: "Pattern Creator"))
                        .frame(maxWidth: biographyCase == "narrow" || biographyCase == "dynamic" ? 320 : .infinity)
                }.dynamicTypeSize(biographyCase == "dynamic" ? .accessibility2 : .large)
            } else if ready {
                MainTabs(selectedTab: $selectedTab, onTimelineTap: { timelineTopRequest53 += 1 }, onTimelineDoubleTap: { timelineRestartRequest53 += 1 },
                         timeline: TimelineView(isVisible: selectedTab == 0, restartRequest: timelineRestartRequest53, topRequest: timelineTopRequest53), authors: LeaderboardView(),
                         search: SearchView(), settings: SettingsView())
            } else { ProgressView() }
        }
        .frame(maxWidth: VisualControlsQA.width ?? (ProcessInfo.processInfo.arguments.contains("--qa-theme-compact") ? 320 : .infinity))
        .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("--qa-theme-compact") || VisualControlsQA.largeType ? .accessibility2 : .large)
        // The QA transport control covers only the existing 104pt timeline
        // header, outside the native media viewport. It never resizes the deck.
        .overlay(alignment: .topTrailing) { if AutoContinuationQA.enabled { AutoContinuationQAReadback() } }
        .overlay(alignment: .topLeading) { if CollectionPagingQA.playbackDiagnosticMode != nil { PlaybackDiagnostics43Readback() } }
        .overlay(alignment: .bottomTrailing) {
            if ready && ProcessInfo.processInfo.arguments.contains("--qa-poster-late51") {
                Button("生成测试封面") {
                    do {
                        guard let source = posterDetailsItem50.mediaURL,
                              let frame = MediaImageDecoder.preview(CollectionPagingQA.root.appendingPathComponent("pattern-2.png"), pixels: 384),
                              let data = UIImage(cgImage: frame).jpegData(compressionQuality: 0.85) else {
                            throw ImageLoadError.decode
                        }
                        try MediaCache.shared.storeGeneratedPoster(data, source: source,
                            expectedGeneration: MediaCache.shared.repairGeneration)
                        latePosterWrite51 = "written"
                    } catch { latePosterWrite51 = "failed" }
                }
                .accessibilityIdentifier("poster.qa.generate51")
                .accessibilityValue(latePosterWrite51)
                .padding(12)
            }
        }
        .task {
            do {
                try CollectionPagingQA.prepare()
                try await CollectionPagingQA.validateWideVideoIfRequested()
                try await CollectionPagingQA.preparePlaybackDiagnosticsIfRequested()
                if AutoContinuationQA.enabled { try await AutoContinuationQA.prepare() }
                session.configureForCollectionPagingQA()
                if ViewportAuditQA.enabled { try await ViewportAuditQA.prepare(session: session) }
                ready = true
            }
            catch { session.message = "Unable to prepare paging fixtures" }
        }
    }
    static func biography(_ value: String) -> String {
        switch value {
        case "empty": return ""
        case "short": return "Images and video."
        case "chinese": return "这是一段用于检查作者简介排版的中文测试内容。正文使用页面全宽，默认只显示两行。\n\n第二段保留原来的段落，不会把展开按钮挤到正文右侧。\n\n末段用于确认收起后的高度和阅读顺序。"
        case "url": return "Creator portfolio:\nhttps://example.com/" + String(repeating: "portfolio-segment-", count: 10) + "\n\nLinks use the original safe destination and wrap within the available width."
        default: return "A creator working with images and videos. This paragraph is long enough to verify that the biography uses the available width and truncates after exactly two lines.\n\nThe second paragraph stays separate when expanded.\n\nA final paragraph for a controlled layout check."
        }
    }
}

struct MediaPreloadQAReadback: View {
    let preloader: MediaPreloader
    var pagingAllowed = true
    @State private var value = "pending"
    var body: some View {
        Text(value).font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
            .accessibilityIdentifier("media.qa.prefetch").accessibilityValue(value)
            .task(id: pagingAllowed) {
                while !Task.isCancelled {
                    let state = preloader.snapshot
                    value = "active=\(state.active);desired=\(state.desired);ready=\(state.ready);failed=\(state.failed);networkPaused=\(state.networkPaused);pagingAllowed=\(pagingAllowed)"
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
            }
    }
}

private struct PlaybackDiagnostics43Readback: View {
    @State private var value = "[]"
    var body: some View {
        Text(value).font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
            .accessibilityElement(children: .ignore).accessibilityIdentifier("qa.playback-diagnostics43")
            .accessibilityLabel("Playback diagnostic fixture readback")
            .accessibilityValue(value)
            .task {
                while !Task.isCancelled {
                    if let entries = try? await LocalDiagnosticsStore.shared.entries() {
                        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
                        if let data = try? encoder.encode(entries.filter {
                            $0.area == .playback || (CollectionPagingQA.playbackDiagnosticMode == "poster-stream49" && $0.area == .thumbnail)
                        }) { value = String(decoding: data, as: UTF8.self) }
                    }
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                }
            }
    }
}

struct CollectionPagingQAFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

struct CollectionPagingQAObserver: ViewModifier {
    let focused: Int?
    @State private var frames: [String: CGRect] = [:]
    private var value: String {
        guard let viewport = frames["viewport"], let focused, let page = frames["page-\(focused)"] else { return "waiting" }
        let others = frames.filter { $0.key.hasPrefix("page-") && $0.key != "page-\(focused)" }
        let overlaps = others.values.filter { $0.intersection(viewport).width > 1 && $0.intersection(viewport).height > 1 }.count
        let base = "focused=\(focused);viewportY=\(viewport.minY);viewportH=\(viewport.height);pageY=\(page.minY);pageH=\(page.height);viewportX=\(viewport.minX);viewportW=\(viewport.width);pageX=\(page.minX);pageW=\(page.width);neighborOverlap=\(overlaps)"
        guard VisualControlsQA.enabled else { return base }
        let extra = ["favorite", "details", "mute", "rotate", "follow", "author", "social", "follow.text", "favorite.icon", "details.icon", "mute.icon", "rotate.icon", "follow.icon"].compactMap { name -> String? in
            guard let frame = frames["control.\(focused).\(name)"] else { return nil }
            let key = name.replacingOccurrences(of: ".", with: "_")
            return "\(key)X=\(frame.minX);\(key)Y=\(frame.minY);\(key)W=\(frame.width);\(key)H=\(frame.height)"
        }.joined(separator: ";")
        return base + ";" + extra
    }
    func body(content: Content) -> some View {
        if CollectionPagingQA.enabled {
            content.onPreferenceChange(CollectionPagingQAFrameKey.self) { frames = $0; record($0) }
                .overlay(alignment: .topTrailing) {
                    Text(value).font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                        .accessibilityIdentifier("collection.qa.geometry").accessibilityValue(value)
                }
        } else { content }
    }
    private func record(_ values: [String: CGRect]) {
        let rectangles = values.mapValues { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }
        var scrolls: [[String: Any]] = []
        if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) {
            func visit(_ view: UIView) {
                if let scroll = view as? UIScrollView {
                    let frame = scroll.convert(scroll.bounds, to: window)
                    scrolls.append(["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height,
                                    "offsetY": scroll.contentOffset.y, "insetTop": scroll.adjustedContentInset.top, "insetBottom": scroll.adjustedContentInset.bottom,
                                    "contentHeight": scroll.contentSize.height])
                }
                view.subviews.forEach(visit)
            }
            visit(window)
        }
        let object: [String: Any] = ["focused": focused as Any? ?? NSNull(), "frames": rectangles, "scrolls": scrolls]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            try? data.write(to: CollectionPagingQA.root.appendingPathComponent("geometry.json"), options: .atomic)
        }
    }
}
#endif
