#if DEBUG && targetEnvironment(simulator)
import Foundation

/// Disposable simulator-only metadata. Never writes to the real history root,
/// never uses mature media, and never mutates the site's account or collections.
@MainActor enum HistoryQA {
    static var rootURL: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CivitHistoryQA") }
    static func seed(session: SiteSession) async {
        let key = BrowsingHistory.key(session.tagLibraryOwnerID)
        let db = BrowsingHistoryDatabase(fileURL: rootURL.appendingPathComponent(key).appendingPathComponent("history.json"), ownerKey: key)
        do {
            guard try await db.load().records.isEmpty else { return }
            let video = try await session.mediaPage(filter: FeedFilter(kind: .video, sort: "Most Reactions", period: "AllTime", onlyPG: true), cursor: nil, creator: nil, includeTags: true)
            let image = try await session.mediaPage(filter: FeedFilter(kind: .image, sort: "Most Reactions", period: "AllTime", onlyPG: true), cursor: nil, creator: nil, includeTags: true)
            let items = (Array(video.items.prefix(3)) + Array(image.items.prefix(5))).filter { $0.browsingLevel == 1 }
            for (index, item) in items.enumerated() {
                _ = try await db.record(HistoryRecord(id: item.id, kind: item.isVideo ? .video : .image, authorName: item.username,
                                                     creatorID: item.creatorID, viewedAt: Date().addingTimeInterval(-Double(index) * 18_000)))
            }
            if let first = items.first {
                _ = try await db.checkpoint(.init(lane: .recommendation, filter: FeedFilter(onlyPG: true), ids: items.map(\.id), focusedID: first.id, updatedAt: Date()))
            }
        } catch { /* The native page exposes an empty/retry state if the site is unavailable. */ }
    }
    static func seekReadback(requested: Double, actual: Double, finished: Bool) {
        guard requested.isFinite, actual.isFinite else { return }
        let value: [String: Any] = ["source": "simulator PG history AVPlayer seek completion", "requested": requested,
                                    "actual": actual, "finished": finished, "withinHalfSecond": abs(requested - actual) < 0.5]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            try? data.write(to: rootURL.appendingPathComponent("seek-readback.json"), options: .atomic)
        }
    }
}
#endif

#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import UIKit

/// Local test-pattern video and actual production media/footer components only.
/// This route has no account refresh, tag sync, offline downloads or cloud writes.
@MainActor enum PlaybackLayoutQA {
    static var frames: [String: CGRect] = [:]
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--qa-playback-layout") }
    static var variant: String {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--qa-playback-state"), index + 1 < args.count else { return "idle" }
        return args[index + 1]
    }
    static var landscape: Bool { ProcessInfo.processInfo.arguments.contains("--qa-layout-landscape") }
    static var geometryMatchesTarget: Bool {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }), let window = scene.windows.first(where: \.isKeyWindow) else { return false }
        return scene.interfaceOrientation.isLandscape == landscape && (window.bounds.width > window.bounds.height) == landscape
    }
    static var fixtureURL: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CivitPlaybackLayoutQA/fixture.mp4") }
    static var item: MediaItem {
        var value = MediaItem(id: 900000001, url: "https://example.invalid/local-fixture", width: 480, height: 854, type: "video", username: "TestCreator_With_A_Long_Name", browsingLevel: 1, thumbnail: nil, creatorID: nil, tags: [])
        value.offlineMediaURL = fixtureURL
        return value
    }
    @MainActor static func readback() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }), let window = scene.windows.first(where: \.isKeyWindow) else { return }
        var tracks: [[String: Any]] = []
        func walk(_ view: UIView) {
            if let track = view as? VideoSeekControl.SeekTrackView {
                let rect = track.convert(track.bounds, to: window)
                tracks.append(["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height,
                               "isOpaque": track.isOpaque, "backgroundAlpha": track.backgroundColor?.cgColor.alpha ?? 0,
                               "isUIControl": track.isKind(of: UIControl.self), "positionFraction": track.positionFraction])
            }
            for child in view.subviews { walk(child) }
        }
        walk(window)
        let rectangles = frames.mapValues { rect in ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height] }
        let separated = frames["actions"].flatMap { actions in frames["progress"].map { actions.maxY <= $0.minY } }
        let contained = frames["viewport"].flatMap { viewport in frames["progress"].map { viewport.contains($0) } }
        let value: [String: Any] = ["layoutFrames": rectangles, "actionsProgressSeparated": separated ?? false, "progressWithinContentViewport": contained ?? false, "fixture": "local synthetic color test pattern", "build": Bundle.main.infoDictionary?["CFBundleVersion"] ?? "unknown", "variant": variant,
                                    "policyOrientationMask": ViewingOrientationController.shared.supportedOrientations.rawValue,
                                    "applicationOrientationMask": UIApplication.shared.supportedInterfaceOrientations(for: window).rawValue,
                                    "rootControllerOrientationMask": window.rootViewController?.supportedInterfaceOrientations.rawValue ?? 0,
                                    "orientationMessagePresent": ViewingOrientationController.shared.message != nil,
                                    "requestedLandscape": landscape, "geometryConverged": geometryMatchesTarget,
                                    "windowWidth": window.bounds.width, "windowHeight": window.bounds.height,
                                    "safeAreaTop": window.safeAreaInsets.top, "safeAreaBottom": window.safeAreaInsets.bottom,
                                    "landscape": scene.interfaceOrientation.isLandscape, "trackCount": tracks.count, "tracks": tracks]
        let directory = fixtureURL.deletingLastPathComponent()
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) { try? data.write(to: directory.appendingPathComponent("layout-readback.json"), options: .atomic) }
    }
}

struct PlaybackLayoutQAView: View {
    @State private var focused: Int? = 900000001
    @State private var tab = 0
    @State private var orientationScope = UUID()
    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                ZStack(alignment: .top) {
                    MediaDeck(items: [PlaybackLayoutQA.item], focused: $focused, isVisible: true, showsLoadMore: false,
                              onAuthor: { _ in }, resumePositions: [900000001: 7], loadMore: {}).playbackQAFrame("viewport")
                    VStack(spacing: 18) {
                        HStack(spacing: 28) { Text("关注").opacity(0.5); Text("推荐").bold() }.padding(.top, 7)
                        HStack(spacing: 20) { Text("Images"); Text("全部"); Text("Videos").bold(); Image(systemName: "line.3.horizontal.decrease") }.font(.subheadline)
                    }.foregroundStyle(.white).allowsHitTesting(false)
                }.background(.black).toolbar(.hidden, for: .navigationBar)
            }.tabItem { Label("时间线", systemImage: "rectangle.portrait.on.rectangle.portrait") }.tag(0)
            Color.black.tabItem { Label("作品榜", systemImage: "square.grid.2x2") }.tag(1)
            Color.black.tabItem { Label("作者榜", systemImage: "person.3") }.tag(2)
            Color.black.tabItem { Label("搜索", systemImage: "magnifyingglass") }.tag(3)
            Color.black.tabItem { Label("我", systemImage: "person.crop.circle") }.tag(4)
        }.tint(.white).preferredColorScheme(.dark)
            .onPreferenceChange(PlaybackLayoutQAFrameKey.self) { PlaybackLayoutQA.frames = $0 }
            .task {
                try? await Task.sleep(for: .milliseconds(300))
                ViewingOrientationController.shared.beginViewer(orientationScope)
                let actualLandscape = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.interfaceOrientation.isLandscape ?? false
                if actualLandscape != PlaybackLayoutQA.landscape { ViewingOrientationController.shared.toggleViewerOrientation() }
                try? await Task.sleep(for: .seconds(2))
                for _ in 0..<30 {
                    if PlaybackLayoutQA.geometryMatchesTarget || Task.isCancelled { break }
                    try? await Task.sleep(for: .milliseconds(200))
                }
                try? await Task.sleep(for: .milliseconds(200))
                PlaybackLayoutQA.readback()
            }
            .onDisappear { ViewingOrientationController.shared.endViewer(orientationScope) }
    }
}
struct PlaybackLayoutQAFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

extension View {
    func playbackQAFrame(_ name: String) -> some View {
        background(GeometryReader { geometry in Color.clear.preference(key: PlaybackLayoutQAFrameKey.self, value: [name: geometry.frame(in: .global)]) })
    }
}
#endif
