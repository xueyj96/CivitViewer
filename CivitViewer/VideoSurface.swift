import SwiftUI
import AVFoundation
import UIKit

#if DEBUG && targetEnvironment(simulator)
/// A plain trace must not introduce another SwiftUI render while observing seek.
private final class VideoSeekQAEvents {
    var callbacks = 0
    var commits = 0
    var lastFinished: Bool?
}
#endif

private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    @Binding var readyForDisplay: Bool
    final class Coordinator {
        var observation: NSKeyValueObservation?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        #if DEBUG && targetEnvironment(simulator)
        private let geometryID = UUID()
        private final class GeometryProbe: UIView {
            weak var surface: Surface?
            override var accessibilityValue: String? {
                get { surface?.accessibilityValue }
                set { }
            }
        }
        func enableGeometryReadback() {
            let probe = GeometryProbe(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            probe.surface = self; probe.isUserInteractionEnabled = false
            probe.isAccessibilityElement = true; probe.accessibilityTraits = .staticText
            probe.accessibilityIdentifier = "media.qa.video-geometry"
            probe.accessibilityLabel = "Video layer geometry"
            addSubview(probe)
        }
        override var accessibilityValue: String? {
            get {
                guard ProcessInfo.processInfo.arguments.contains("--qa-chrome-geometry") else { return super.accessibilityValue }
                func rect(_ value: CGRect) -> [String: Double] {
                    ["x": Double(value.minX), "y": Double(value.minY), "width": Double(value.width), "height": Double(value.height)]
                }
                let video = playerLayer.videoRect
                let sourceSize = playerLayer.player?.currentItem?.presentationSize ?? .zero
                let insets = window?.safeAreaInsets ?? .zero
                let transform = self.transform
                let object: [String: Any] = [
                    "surface": geometryID.uuidString,
                    "window": window.map { rect($0.bounds) } ?? [:],
                    "windowSafeArea": ["top": Double(insets.top), "bottom": Double(insets.bottom), "left": Double(insets.left), "right": Double(insets.right)],
                    "surfaceBounds": rect(bounds),
                    "surfaceWindow": window.map { rect(convert(bounds, to: $0)) } ?? [:],
                    "layerBounds": rect(playerLayer.bounds), "layerFrame": rect(playerLayer.frame),
                    "videoRect": rect(video),
                    "presentationSize": ["width": Double(sourceSize.width), "height": Double(sourceSize.height)],
                    "sourceScale": ["x": sourceSize.width > 0 ? Double(video.width / sourceSize.width) : 0,
                                    "y": sourceSize.height > 0 ? Double(video.height / sourceSize.height) : 0],
                    "videoWindow": window.map { rect(convert(video, to: $0)) } ?? [:],
                    "gravity": playerLayer.videoGravity.rawValue,
                    "ready": playerLayer.isReadyForDisplay,
                    "transform": ["a": Double(transform.a), "b": Double(transform.b), "c": Double(transform.c), "d": Double(transform.d), "tx": Double(transform.tx), "ty": Double(transform.ty)]
                ]
                guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
                return String(data: data, encoding: .utf8)
            }
            set { super.accessibilityValue = newValue }
        }
        #endif
    }
    func makeUIView(context: Context) -> Surface {
        let view = Surface(); view.playerLayer.videoGravity = .resizeAspect; view.playerLayer.player = player
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--qa-chrome-geometry") {
            view.enableGeometryReadback()
        }
        #endif
        context.coordinator.observation = view.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
            let ready = layer.isReadyForDisplay
            DispatchQueue.main.async { if layer.player === player { readyForDisplay = ready } }
        }
        return view
    }
    func updateUIView(_ view: Surface, context: Context) { view.playerLayer.player = player }
    static func dismantleUIView(_ view: Surface, coordinator: Coordinator) { coordinator.observation = nil; view.playerLayer.player = nil }
}


struct VideoProgressChrome: View {
    let position: Double
    let duration: Double
    let bufferedRanges: [SeekTimeRange]
    let enabled: Bool
    let emphasized: Bool
    let showTimes: Bool
    let onSeek: (Double, MediaPanPhase) -> Void
    let onInteractionChange: (Bool) -> Void
    var preparationVisible = false
    var preparationProgress: Double? = nil
    var preparationCanCancel = false
    var onPreparationCancel: () -> Void = {}
    var body: some View {
        ZStack(alignment: .topLeading) {
            VideoSeekControl(position: position, duration: duration, bufferedRanges: bufferedRanges, enabled: enabled && !preparationCanCancel,
                             interactionActive: emphasized, onSeek: onSeek, onInteractionChange: onInteractionChange)
                .frame(height: 44)
                .allowsHitTesting(!preparationCanCancel).zIndex(0)
            HStack {
                Text(clock(position)); Spacer(); Text(duration > 0 ? clock(duration) : "--:--")
            }.font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                .frame(height: 14).padding(.top, 20)
                .opacity(showTimes && !preparationVisible ? 1 : 0)
                .allowsHitTesting(false).accessibilityHidden(!showTimes || preparationVisible)
            if preparationVisible {
                VideoPreparationOverlay(visible: true,
                    progress: preparationProgress, canCancel: preparationCanCancel,
                    onCancel: onPreparationCancel)
                    .zIndex(1)
            }
        }
        .frame(height: 44)
        .accessibilityElement(children: .contain).accessibilityIdentifier("media.progress-band")
        .animation(.easeOut(duration: 0.16), value: showTimes)
        #if DEBUG && targetEnvironment(simulator)
        .playbackQAFrame("progress")
        #endif
    }
    private func clock(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "--:--" }
        let seconds = Int(min(value, Double(Int.max - 1)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct VideoSurface<Footer: View>: View {
    let url: URL
    let poster: URL?
    let active: Bool
    var diagnosticWorkID: Int? = nil
    var diagnosticOffline = false
    var gesturesActive: Bool? = nil
    var gestureTopExclusion: CGFloat = 110
    var gestureExcludedFrames: [CGRect] = []
    var chromeHidden = false
    var onChromeHold: (() -> Void)? = nil
    var pausedForOverlay = false
    var retainDuringInterruption = false
    var mediaBlurred = false
    var onKindSwipe: ((Int) -> Void)? = nil
    var onKindDrag: ((Double, MediaPanPhase) -> Void)? = nil
    var onDoubleTap: (() -> Void)? = nil
    var refreshURL: (() async throws -> URL?)? = nil
    var onConfirmedUnavailable: (() -> Void)? = nil
    var resumePosition: Double? = nil
    var onProgress: ((Double, Double, Bool) -> Void)? = nil
    var onDisplayReady: ((Bool) -> Void)? = nil
    var onImageContent: (() -> Void)? = nil
    let footer: (Binding<Bool>) -> Footer
    @ObservedObject private var chrome = ViewingChromeController.shared
    @AppStorage("autoplay") private var autoplay = true
    @AppStorage("muted") private var muted = true
    @AppStorage("automaticVideoRepair") private var automaticVideoRepair = true
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.viewingBottomBarHeight) private var bottomBarHeight
    @State private var player: AVPlayer?
    @State private var actualSourceURL: URL?
    @State private var preloadDemandOwner = UUID()
    #if DEBUG
    @State private var measuredStartupAt: TimeInterval?
    @State private var measuredFirstFrame = false
    #endif
    @State private var actualSourceKind: PlaybackDiagnosticSource = .network
    @State private var compatibilityAvailable = false
    @State private var nativeRetrySuspended = false
    @State private var compatibilityPosition: Double?
    @State private var compatibilityRequest: CompatibilityRequest?
    @State private var repairedSource: MediaRepair.Result?
    @State private var posterRetry = 0
    @State private var posterNeedsFrame = false
    @State private var posterCaptureTried = false
    @State private var posterVideoOutput: AVPlayerItemVideoOutput?
    @State private var posterOutputItem: AVPlayerItem?
    @State private var posterSampleAttempts = 0
    @State private var posterCaptureTask: Task<Void, Never>?
    @State private var posterExpiryTask: Task<Void, Never>?
    @State private var posterCaptureID: UUID?
    @State private var bypassRepaired = false
    @State private var repairAttempted = false
    @State private var repairStage: MediaRepairStage?
    @State private var repairProgress: Double?
    @State private var preparationGestureFrame: CGRect = .zero
    #if DEBUG && targetEnvironment(simulator)
    @State private var qaPreparationCancelled = false
    @State private var qaBuffering = true
    private var qaPreparationActive: Bool {
        VisualControlsQA.enabled && ProcessInfo.processInfo.arguments.contains("--qa-preparation58") &&
            !qaPreparationCancelled && active
    }
    #endif
    @State private var repairedPinnedURL: URL?
    @State private var repairPlayingRecorded = false
    @State private var repairFirstPosition: Double?
    private struct CompatibilityRequest: Identifiable {
        let id = UUID()
        let requestedURL: URL
        let sourceURL: URL
        let sourceKind: PlaybackDiagnosticSource
        let workID: Int?
        let initialPosition: Double?
    }
    #if DEBUG && targetEnvironment(simulator)
    @State private var qaPlayerID: UUID?
    @State private var qaPrepareCount = 0
    @State private var qaCreationCount = 0
    @State private var qaTapCount = 0
    @State private var qaRateHoldCount = 0
    @State private var qaSeekStartCount = 0
    @State private var qaSeekEvents = VideoSeekQAEvents()
    #endif
    @State private var playing = false
    @State private var playbackFailed = false
    @State private var itemReady = false
    @State private var readyForDisplay = false
    @State private var waitingForData = true
    @State private var currentTime = 0.0
    @State private var duration = 0.0
    @State private var bufferedRanges: [SeekTimeRange] = []
    @State private var statusObserver: NSKeyValueObservation?
    @State private var playbackObserver: NSKeyValueObservation?
    @State private var bufferObserver: NSKeyValueObservation?
    @State private var durationObserver: NSKeyValueObservation?
    @State private var seekableObserver: NSKeyValueObservation?
    @State private var seekRanges: [SeekTimeRange] = []
    @State private var timeObserver: Any?
    private struct PlayerEventToken: Equatable {
        let id = UUID()
        let item: ObjectIdentifier
        let generation: Int
    }
    @State private var playerStatusEvent: PlayerEventToken?
    @State private var playerReprepareEvent: PlayerEventToken?
    @State private var playerSyncEvent: PlayerEventToken?
    @State private var seekingBase: Double?
    @State private var seekTarget: Double?
    @State private var holdingRate = false
    @State private var wasPlayingBeforeHold = false
    @State private var resolvedURL: URL?
    @State private var pinnedURL: URL?
    @State private var recoveryAttempted = false
    @State private var recovering = false
    @State private var recoveryMessage = "视频暂时无法播放"
    @State private var recoveryTask: Task<Void, Never>?
    @State private var playbackGeneration = 0
    @State private var failureHandled = false
    @State private var resumeApplied = false
    @State private var resumeInFlight = false
    @State private var interactiveSeekID: UUID?
    @State private var recoveryPosition: Double?
    @State private var resumeCursor = PlaybackResumeCursor()
    @State private var userIntent = PlaybackUserIntent()
    @State private var barInteractionActive = false
    private var chromePosition: Double {
        #if DEBUG && targetEnvironment(simulator)
        if PlaybackLayoutQA.enabled && PlaybackLayoutQA.variant != "live" { return PlaybackLayoutQA.variant == "zero" ? 0 : 9 }
        #endif
        return seekTarget ?? currentTime
    }
    private var chromeDuration: Double {
        #if DEBUG && targetEnvironment(simulator)
        if PlaybackLayoutQA.enabled && PlaybackLayoutQA.variant != "live" { return PlaybackLayoutQA.variant == "unknown" ? 0 : 30 }
        #endif
        return duration
    }
    private var chromeBufferedRanges: [SeekTimeRange] {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--qa-buffering62") {
            return [.init(start: 0, end: 6), .init(start: 12, end: 18)]
        }
        if PlaybackLayoutQA.enabled && PlaybackLayoutQA.variant != "live" { return [.init(start: 0, end: 18)] }
        #endif
        return bufferedRanges
    }
    private var chromeEmphasized: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if PlaybackLayoutQA.enabled && PlaybackLayoutQA.variant != "live" { return ["seeking", "paused"].contains(PlaybackLayoutQA.variant) }
        #endif
        return barInteractionActive || seekingBase != nil || resumeInFlight || (itemReady && !playing)
    }
    private var chromeShowsTimes: Bool { chromeEmphasized }
    private var requestedResume: Double? { resumeCursor.requested(initial: resumePosition, recovery: recoveryPosition) }
    private var awaitingResume: Bool { resumeInFlight || (requestedResume != nil && !resumeApplied) }
    private var canScrub: Bool { active && itemReady && duration > 0 && !resumeInFlight && !playbackFailed && !seekRanges.isEmpty }
    private var loading: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if PlaybackLayoutQA.enabled && PlaybackLayoutQA.variant != "live" { return PlaybackLayoutQA.variant == "buffering" }
        if VisualControlsQA.enabled && ProcessInfo.processInfo.arguments.contains("--qa-buffering62") && qaBuffering { return active }
        #endif
        return active && !playbackFailed && seekTarget == nil && (awaitingResume || !itemReady || ((playing || holdingRate) && (waitingForData || !readyForDisplay)))
    }
    private var preparingVideo: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if qaPreparationActive { return true }
        #endif
        return active && (loading || (playbackFailed && (recovering || repreparePending)))
    }
    private var repreparePending: Bool { currentItem(matching: playerReprepareEvent) != nil }
    private var currentVideoWaiting: Bool {
        active && scenePhase == .active && !chromeHidden && !pausedForOverlay &&
            (gesturesActive ?? active) && seekTarget == nil && preparingVideo &&
            (playing || holdingRate || (recovering && userIntent.shouldPlay(autoplay: autoplay)))
    }
    private var repairingVideo: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if qaPreparationActive { return true }
        #endif
        return recovering && repairStage != nil
    }
    private var preparationCanCancel: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if qaPreparationActive { return (gesturesActive ?? active) && !chromeHidden && !pausedForOverlay }
        #endif
        return preparingVideo && recovering && repairStage != nil && (gesturesActive ?? active) && !chromeHidden && !pausedForOverlay
    }
    private var effectiveGestureExcludedFrames: [CGRect] {
        guard !chromeHidden else { return [] }
        var frames = gestureExcludedFrames
        if preparationCanCancel && !preparationGestureFrame.isEmpty {
            frames.append(preparationGestureFrame)
        }
        return frames
    }
    private var preparationFraction: Double? {
        #if DEBUG && targetEnvironment(simulator)
        if qaPreparationActive { return 0.65 }
        #endif
        if repairStage == .transcoding || repairStage == .downloading { return repairProgress }
        return nil
    }
    var body: some View {
        ZStack {
            Group {
                CachedPoster(source: url, declared: poster, active: active, fit: true,
                    retryToken: posterRetry, diagnosticWorkID: diagnosticWorkID,
                    onFailure: { failed in
                        if failed { posterNeedsFrame = true; installPosterOutput() }
                    })
                if let player {
                    // A replacement player owns a new layer observation. Reusing
                    // the old representable retains its captured player identity.
                    PlayerLayerView(player: player, readyForDisplay: $readyForDisplay)
                        .id(ObjectIdentifier(player)).opacity(awaitingResume ? 0 : 1)
                }
            }.blur(radius: mediaBlurred ? 24 : 0)
            VideoWaitingIndicator(visible: currentVideoWaiting)
            if playbackFailed && !recovering && !repreparePending {
                VStack(spacing: 12) {
                    Text(recoveryMessage).foregroundStyle(.white)
                    Button("重试") { nativeRetrySuspended = false; repairAttempted = false; release(); prepare() }
                        .buttonStyle(AppActionButtonStyle(tone: .neutral))
                    if compatibilityAvailable {
                        Button("兼容播放", action: openCompatibility)
                            .buttonStyle(AppActionButtonStyle(tone: .accent))
                            .accessibilityIdentifier("media.compatibility.open")
                    }
                }
                .font(.caption)
                .padding()
                .background(Color.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .viewingChromeHidden(chromeHidden)
            } else if active && !playbackFailed && !playing && !holdingRate && !currentVideoWaiting && seekTarget == nil {
                Image(systemName: "play.fill").font(.title).foregroundStyle(.white)
                    .frame(width: 64, height: 64).background(.black.opacity(0.35), in: Circle())
                    .allowsHitTesting(false).accessibilityHidden(true).viewingChromeHidden(chromeHidden)
            }
            if let seekTarget {
                Text(Self.time(seekTarget)).font(.title2.monospacedDigit().bold()).padding(18).background(.black.opacity(0.65), in: Capsule()).allowsHitTesting(false).viewingChromeHidden(chromeHidden)
            } else if holdingRate {
                VStack { Text("2× 播放").font(.headline).padding(12).background(.black.opacity(0.65), in: Capsule()).padding(.top, 120); Spacer() }.allowsHitTesting(false).viewingChromeHidden(chromeHidden)
            }
            VStack {
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    footer($muted)
                    Group {
                    if active && (!playbackFailed || recovering || repreparePending) {
                        VideoProgressChrome(position: chromePosition, duration: chromeDuration, bufferedRanges: chromeBufferedRanges,
                                            enabled: canScrub && chromeDuration > 0, emphasized: chromeEmphasized,
                                            showTimes: chromeShowsTimes, onSeek: scrub,
                                            onInteractionChange: { barInteractionActive = $0 },
                                            preparationVisible: repairingVideo,
                                            preparationProgress: preparationFraction, preparationCanCancel: preparationCanCancel,
                                            onPreparationCancel: cancelRepair)
                    } else { Color.clear.frame(height: 44).accessibilityHidden(true) }
                    }.frame(height: 44)
                }.padding(.horizontal, 20).padding(.bottom, bottomBarHeight)
                    .viewingChromeHidden(chromeHidden)
            }

        }
        .overlayPreferenceValue(VideoPreparationGestureAnchorKey.self) { anchor in
            GeometryReader { proxy in
                Color.clear.preference(
                    key: VideoPreparationGestureFrameKey.self,
                    value: resolvedVideoPreparationFrame(anchor, in: proxy)
                )
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .coordinateSpace(name: VideoPreparationGestureSpace.name)
        .onPreferenceChange(VideoPreparationGestureFrameKey.self) { frame in
            let next = preparationCanCancel ? frame : .zero
            if preparationGestureFrame != next { preparationGestureFrame = next }
        }
        .background {
            MediaGestureLayer(active: (gesturesActive ?? active) && !pausedForOverlay, isVideo: true, topExclusion: chromeHidden ? 0 : gestureTopExclusion, bottomExclusion: chromeHidden ? 0 : bottomBarHeight + 44, excludedFrames: effectiveGestureExcludedFrames, onKindSwipe: onKindSwipe, onKindDrag: onKindDrag, onSeek: seek, onRateHold: holdRate, onTap: togglePlayback, onDoubleTap: onDoubleTap, onChromeHold: onChromeHold)
        }
        #if DEBUG && targetEnvironment(simulator)
        .overlay(alignment: .topTrailing) {
            if VisualControlsQA.enabled && ProcessInfo.processInfo.arguments.contains("--qa-buffering62") && active {
                Button(qaBuffering ? "模拟恢复" : "模拟缓冲") { qaBuffering.toggle() }
                    .accessibilityIdentifier("media.qa.buffering-toggle")
                    .buttonStyle(.bordered).padding(.top, 180)
            }
            if (CollectionPagingQA.enabled || PlaybackLayoutQA.enabled) && active {
                let state = "player=\(qaPlayerID?.uuidString ?? "none");prepare=\(qaPrepareCount);created=\(qaCreationCount);position=\(String(format: "%.3f", currentTime));muted=\(player?.isMuted ?? muted);rate=\(player?.rate ?? 0);chrome=\(chromeHidden);toggles=\(chrome.qaToggleCount);taps=\(qaTapCount);rateHolds=\(qaRateHoldCount);seekStarts=\(qaSeekStartCount)"
                let seekState = ";intent=\(playing);inFlight=\(resumeInFlight);interactivePending=\(interactiveSeekID != nil);seekBase=\(seekingBase != nil);resumeApplied=\(resumeApplied);hasResume=\(requestedResume != nil);active=\(active);overlay=\(pausedForOverlay);ready=\(itemReady);failed=\(playbackFailed);gen=\(playbackGeneration);seekCallbacks=\(qaSeekEvents.callbacks);seekCommits=\(qaSeekEvents.commits);seekFinished=\(qaSeekEvents.lastFinished.map { String($0) } ?? "none");nativePosition=\(String(format: "%.3f", player?.currentTime().seconds ?? -1));timeStatus=\(player?.timeControlStatus.rawValue ?? -1)"
                let nativeState = ";itemStatus=\(player?.currentItem?.status.rawValue ?? -1);itemErrorCode=\((player?.currentItem?.error as NSError?)?.code ?? 0);source=\(actualSourceKind.rawValue)"
                Text(state + seekState + nativeState).font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                    .accessibilityIdentifier("media.qa.player").accessibilityValue(state + seekState + nativeState)
            }
        }
        #endif
        .accessibilityAction(named: Text(playing ? "暂停视频" : "播放视频"), togglePlayback)
        .onAppear { if active { prepare() } }
        .onChange(of: active) { _, value in
            if value { prepare() }
            else {
                if !retainDuringInterruption && resumePosition == nil { resumeCursor.reset(); userIntent.reset() }
                release()
            }
        }
        .onChange(of: url) { _, _ in
            posterNeedsFrame = false
            nativeRetrySuspended = false; compatibilityPosition = nil; compatibilityAvailable = false
            repairedSource = nil; bypassRepaired = false; repairAttempted = false
            release(); if active { prepare() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && repairStage != nil { cancelRepair() }
            if phase != .active { stopPosterCapture() }
            else { posterCaptureTried = false; installPosterOutput() }
            updatePreloadDemand()
        }
        .onChange(of: preparingVideo) { _, _ in updatePreloadDemand() }
        .onChange(of: muted) { _, value in player?.isMuted = value }
        .onChange(of: readyForDisplay) { _, value in
            onDisplayReady?(value && itemReady && !awaitingResume)
            recordMeasuredFirstFrame()
            if value, let player, let item = player.currentItem { capturePosterFrame(player, item: item) }
        }
        .onChange(of: itemReady) { _, _ in recordMeasuredFirstFrame() }
        .onChange(of: playerStatusEvent) { _, event in
            guard let item = currentItem(matching: event) else { return }
            itemReady = item.status == .readyToPlay
            if item.status == .failed { handleFailure(item) }
            updateBuffer(item)
            if itemReady && !pausedForOverlay { applyResume(item) }
        }
        .onChange(of: playerReprepareEvent) { _, event in
            guard active, currentItem(matching: event) != nil else { return }
            playerReprepareEvent = nil
            retirePlayer(); prepare()
        }
        .onChange(of: playerSyncEvent) { _, event in
            guard currentItem(matching: event) != nil else { return }
            syncPlayback(); onDisplayReady?(readyForDisplay && itemReady)
        }
        .onChange(of: duration) { _, _ in
            if itemReady, !pausedForOverlay, let item = player?.currentItem { applyResume(item) }
        }
        .onChange(of: currentTime) { _, _ in observePlaybackProgress() }
        .onChange(of: resumeInFlight) { _, value in
            if value { syncPlayback() }
        }
        .onChange(of: autoplay) { _, value in userIntent.reset(); if active { playing = value; syncPlayback() } }
        .onChange(of: pausedForOverlay) { _, value in
            syncPlayback()
            updatePreloadDemand()
            if value { stopPosterCapture() }
            else { posterCaptureTried = false; installPosterOutput() }
            if !value, let item = player?.currentItem {
                if item.status == .failed { handleFailure(item) }
                else if item.status == .readyToPlay { applyResume(item) }
            }
        }
        .onDisappear { release() }
        .fullScreenCover(item: $compatibilityRequest, onDismiss: {
            onDisplayReady?(false)
        }) { request in
            CompatibilityVideoView(url: request.sourceURL, initialPosition: request.initialPosition,
                onProgress: { position, length, flush in
                    compatibilityPosition = PlaybackResumePolicy.position(position: position, duration: length)
                    onProgress?(position, length, flush)
                }, onPlaying: {
                    onDisplayReady?(true)
                    let context = compatibilityDiagnostic(request, code: nil)
                    LocalDiagnosticsStore.shared.note(area: .playback, code: .compatibilityPlaying, playback: context)
                }, onFailure: { code in
                    let context = compatibilityDiagnostic(request, code: code)
                    LocalDiagnosticsStore.shared.note(area: .playback, code: .playbackFailed, count: 2, playback: context)
                })
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
            guard let current = player?.currentItem, let ended = note.object as? AVPlayerItem, current === ended, active else { return }
            onProgress?(0, duration, true)
            player?.seek(to: .zero); syncPlayback()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { note in
            guard let current = player?.currentItem, let failed = note.object as? AVPlayerItem, current === failed, active else { return }
            handleFailure(failed, notificationError: note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)
        }
    }
    private func currentItem(matching event: PlayerEventToken?) -> AVPlayerItem? {
        guard let event, event.generation == playbackGeneration,
              let item = player?.currentItem, ObjectIdentifier(item) == event.item else { return nil }
        return item
    }
    private func prepare() {
        guard active, !nativeRetrySuspended else { return }
        #if DEBUG && targetEnvironment(simulator)
        qaPrepareCount += 1
        #endif
        if player == nil {
            #if DEBUG
            measuredStartupAt = ProcessInfo.processInfo.systemUptime; measuredFirstFrame = false
            #endif
            playbackFailed = false; compatibilityAvailable = false; failureHandled = false; itemReady = false; readyForDisplay = false; waitingForData = true
            repairPlayingRecorded = false; repairFirstPosition = nil
            resumeApplied = false; resumeInFlight = false; onDisplayReady?(false)
            currentTime = 0; duration = 0; bufferedRanges = []; playing = userIntent.shouldPlay(autoplay: autoplay)
            let address = resolvedURL ?? url
            MediaCache.shared.pin(address); pinnedURL = address
            if repairedSource == nil && !bypassRepaired { repairedSource = MediaRepair.shared.cached(address, offline: diagnosticOffline) }
            let source = repairedSource?.url ?? (recoveryAttempted ? address : (MediaCache.shared.cached(address, video: true) ?? address))
            if repairedSource != nil { MediaCache.shared.protectRepairFile(source); repairedPinnedURL = source }
            actualSourceURL = source
            actualSourceKind = diagnosticOffline && address.isFileURL && source.isFileURL &&
                source.deletingLastPathComponent() == address.deletingLastPathComponent() ? .offline : (source != address && source.isFileURL ? .cache :
                (source.isFileURL ? (diagnosticOffline ? .offline : .local) : .network)
            )
            updatePreloadDemand(waiting: true)
            let item = AVPlayerItem(url: source); item.preferredForwardBufferDuration = 4
            let value = AVPlayer(playerItem: item); value.automaticallyWaitsToMinimizeStalling = true
            value.isMuted = muted; player = value
            posterCaptureTried = false; installPosterOutput()
            #if DEBUG && targetEnvironment(simulator)
            qaPlayerID = UUID(); qaCreationCount += 1
            #endif
            let observedGeneration = playbackGeneration
            statusObserver = item.observe(\.status, options: [.initial, .new]) { item, _ in
                Task { @MainActor in
                    guard player?.currentItem === item, observedGeneration == playbackGeneration else { return }
                    // Only publish identity-bound native state here. Playback
                    // decisions belong to the current View, after overlay/focus
                    // changes, rather than the View that installed this KVO.
                    playerStatusEvent = .init(item: ObjectIdentifier(item), generation: observedGeneration)
                }
            }
            playbackObserver = value.observe(\.timeControlStatus, options: [.initial, .new]) { value, _ in
                Task { @MainActor in
                    guard player === value else { return }
                    waitingForData = value.timeControlStatus == .waitingToPlayAtSpecifiedRate
                }
            }
            bufferObserver = item.observe(\.loadedTimeRanges, options: [.initial, .new]) { item, _ in
                Task { @MainActor in
                    guard player?.currentItem === item else { return }
                    updateBuffer(item)
                }
            }
            durationObserver = item.observe(\.duration, options: [.initial, .new]) { item, _ in
                Task { @MainActor in guard player?.currentItem === item else { return }; updateBuffer(item) }
            }
            seekableObserver = item.observe(\.seekableTimeRanges, options: [.initial, .new]) { item, _ in
                Task { @MainActor in guard player?.currentItem === item else { return }; updateBuffer(item) }
            }
            timeObserver = value.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { time in
                guard player === value else { return }
                currentTime = time.seconds.isFinite ? max(0, time.seconds) : 0
                updateBuffer(item)
            }
        }
        syncPlayback()
    }
    private func togglePlayback() {
        guard active, !pausedForOverlay, !playbackFailed, seekingBase == nil, !holdingRate else { return }
        #if DEBUG && targetEnvironment(simulator)
        qaTapCount += 1
        #endif
        if player == nil { prepare() }
        playing.toggle(); userIntent.setPlaying(playing); syncPlayback()
        if playing { posterCaptureTried = false; installPosterOutput() }
    }
    private func installPosterOutput() {
        guard posterNeedsFrame else { return }
        guard posterVideoOutput == nil, posterCaptureTask == nil else { return }
        let deferred: PosterDiagnosticStage?
        if !active || scenePhase != .active { deferred = .waitingForActivity }
        else if pausedForOverlay { deferred = .waitingForOverlay }
        else if nativeRetrySuspended || playbackFailed { deferred = .waitingForPlayback }
        else if player?.currentItem == nil { deferred = .waitingForPlayer }
        else if posterCaptureTried { deferred = .waitingForPriorAttempt }
        else { deferred = nil }
        if let deferred { noteFramePoster(.posterDeferred, error: nil, failure: nil, stage: deferred); return }
        guard let item = player?.currentItem else { return }
        if MediaCache.shared.hasGeneratedPoster(url) { posterNeedsFrame = false; posterRetry += 1; return }
        posterCaptureTried = true; posterSampleAttempts = 0
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        output.suppressesPlayerRendering = false
        item.add(output); posterVideoOutput = output; posterOutputItem = item
        noteFramePoster(.posterCaptureStarted, error: nil, failure: nil)
        let operation = UUID(); posterCaptureID = operation
        posterExpiryTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(15)); try Task.checkCancellation() } catch { return }
            guard posterCaptureID == operation, player?.currentItem === item else { return }
            noteFramePoster(.posterFailed, error: nil, failure: .frameUnavailable)
            stopPosterCapture()
        }
    }
    private func capturePosterFrame(_ value: AVPlayer, item: AVPlayerItem) {
        guard player === value, value.currentItem === item, active, scenePhase == .active,
              !pausedForOverlay, itemReady, readyForDisplay, !awaitingResume, !playbackFailed,
              posterOutputItem === item, let output = posterVideoOutput else { return }
        posterSampleAttempts += 1
        let time = value.currentTime()
        guard time.isValid, time.seconds.isFinite, time.seconds >= 0,
              output.hasNewPixelBuffer(forItemTime: time),
              let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else {
            if posterSampleAttempts >= 8 {
                noteFramePoster(.posterFailed, error: nil, failure: .frameUnavailable)
                stopPosterCapture()
            }
            return
        }
        item.remove(output); posterVideoOutput = nil; posterOutputItem = nil
        guard let operation = posterCaptureID else { return }
        let frame = VideoPosterPixelBuffer(pixelBuffer)
        let generation = playbackGeneration, source = url
        let cacheGeneration = MediaCache.shared.repairGeneration
        let sourceIdentity = source.isFileURL ? MediaRepairStore.identity(source) : nil
        posterCaptureTask = Task { @MainActor in
            defer {
                if posterCaptureID == operation {
                    posterExpiryTask?.cancel(); posterExpiryTask = nil
                    posterCaptureTask = nil; posterCaptureID = nil
                }
            }
            var stage = PosterDiagnosticStage.decodedFrame
            do {
                let rendered = try await VideoPosterProcessor.shared.process(frame, item: item)
                try Task.checkCancellation()
                guard posterCaptureID == operation, active, scenePhase == .active, !pausedForOverlay,
                      generation == playbackGeneration, player === value, value.currentItem === item,
                      url == source, !playbackFailed else { return }
                if source.isFileURL {
                    guard sourceIdentity != nil, MediaRepairStore.identity(source) == sourceIdentity else { return }
                }
                stage = .cacheWrite
                try MediaCache.shared.storeGeneratedPoster(rendered.data, source: source, expectedGeneration: cacheGeneration)
                posterNeedsFrame = false; posterRetry += 1
                noteFramePoster(.posterCaptured, error: nil, failure: nil)
            } catch is CancellationError {} catch {
                guard posterCaptureID == operation, generation == playbackGeneration,
                      player === value, value.currentItem === item, active else { return }
                let kind: PosterFailureKind = (error as? VideoPosterFrameError) == .unsupported ? .unsupported :
                    PosterDiagnosticPolicy.failure(error, stage: stage)
                noteFramePoster(.posterFailed, error: error, failure: kind, stage: stage)
            }
        }
    }
    private func noteFramePoster(_ code: DiagnosticCode, error: Error?, failure: PosterFailureKind?, stage: PosterDiagnosticStage = .decodedFrame) {
        let context = PlaybackFailureDiagnostic(workID: diagnosticWorkID, source: actualSourceKind,
            requestedURL: url, sourceURL: actualSourceURL ?? url, recoveryAttempted: posterCaptureTried,
            error: error.map { $0 as NSError }, eventStatusCodes: [], posterStage: stage, posterFailure: failure)
        guard let context else { return }
        LocalDiagnosticsStore.shared.note(area: .thumbnail, code: code, playback: context)
    }
    private func stopPosterCapture() {
        posterExpiryTask?.cancel(); posterExpiryTask = nil
        posterCaptureTask?.cancel(); posterCaptureTask = nil; posterCaptureID = nil
        if let output = posterVideoOutput { posterOutputItem?.remove(output) }
        posterVideoOutput = nil; posterOutputItem = nil
    }
    private func syncPlayback() {
        let awaitingResume = requestedResume != nil && !resumeApplied
        if active && !pausedForOverlay && !resumeInFlight && !awaitingResume && seekingBase == nil && (playing || holdingRate) {
            player?.rate = holdingRate ? 2 : 1
        } else { captureProgress(flush: true); player?.pause() }
    }
    private func applyResume(_ item: AVPlayerItem) {
        guard !resumeApplied, let value = player, value.currentItem === item else { return }
        // A ready item can publish its finite duration later. Keep the seed
        // pending until that value is known instead of silently dropping it.
        if PlaybackResumePolicy.waitsForDuration(position: requestedResume, duration: duration) { return }
        resumeApplied = true
        guard let target = PlaybackResumePolicy.position(position: requestedResume, duration: duration), target > 0 else {
            recoveryPosition = nil; syncPlayback(); onDisplayReady?(readyForDisplay); return
        }
        resumeInFlight = true
        let generation = playbackGeneration
        value.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor in
                guard player === value, value.currentItem === item, generation == playbackGeneration else { return }
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("--qa-history-screen") {
                    HistoryQA.seekReadback(requested: target, actual: value.currentTime().seconds, finished: finished)
                }
                #endif
                resumeInFlight = false; recoveryPosition = nil
                if finished { currentTime = target }
                else { LocalDiagnosticsStore.shared.note(area: .restore, code: .seekFailed) }
                playerSyncEvent = .init(item: ObjectIdentifier(item), generation: generation)
            }
        }
    }
    private func captureProgress(flush: Bool) {
        guard itemReady, !resumeInFlight, duration.isFinite, duration > 0 else { return }
        let position = player?.currentTime().seconds ?? currentTime
        guard position.isFinite, position >= 0 else { return }
        onProgress?(min(position, duration), duration, flush)
    }
    private func updateBuffer(_ item: AVPlayerItem) {
        let seconds = item.duration.seconds
        duration = seconds.isFinite && seconds > 0 ? seconds : 0
        bufferedRanges = item.loadedTimeRanges.map(\.timeRangeValue).compactMap { range in
            let start = range.start.seconds, end = CMTimeRangeGetEnd(range).seconds
            guard start.isFinite, end.isFinite, end > start else { return nil }
            return SeekTimeRange(start: start, end: end)
        }
        seekRanges = item.seekableTimeRanges.map(\.timeRangeValue).compactMap { value in
            let start = value.start.seconds, end = CMTimeRangeGetEnd(value).seconds
            guard start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
            return SeekTimeRange(start: start, end: end)
        }
    }
    private func observePlaybackProgress() {
        guard active, let value = player, let item = value.currentItem else { return }
        capturePosterFrame(value, item: item)
        guard itemReady, !resumeInFlight, !pausedForOverlay, !playbackFailed else { return }
        onProgress?(min(currentTime, duration), duration, false)
        if let repairedSource, active, readyForDisplay, !repairPlayingRecorded, value.timeControlStatus == .playing,
           let baseline = repairFirstPosition, currentTime > baseline + 0.05 {
            repairPlayingRecorded = true
            let context = PlaybackFailureDiagnostic(workID: diagnosticWorkID, source: diagnosticOffline ? .offline : .cache,
                requestedURL: resolvedURL ?? url, sourceURL: repairedSource.url, recoveryAttempted: true,
                error: nil, eventStatusCodes: [], repairMode: repairedSource.transcoded ? .transcode : .remux)
            LocalDiagnosticsStore.shared.note(area: .playback, code: .repairedVideoPlaying, playback: context)
        }
        if readyForDisplay && (repairFirstPosition == nil || currentTime < (repairFirstPosition ?? 0)) { repairFirstPosition = currentTime }
    }
    private func release() {
        recoveryTask?.cancel(); recoveryTask = nil; playbackGeneration += 1
        recoveryAttempted = false; recovering = false; resolvedURL = nil
        repairStage = nil; repairProgress = nil
        repairAttempted = false
        retirePlayer()
        recoveryPosition = nil
    }
    private func retirePlayer() {
        MediaCache.shared.removeForegroundVideoDemand(owner: preloadDemandOwner)
        stopPosterCapture()
        interactiveSeekID = nil
        if !resumeInFlight, itemReady, duration > 0 {
            resumeCursor.capture(position: player?.currentTime().seconds ?? currentTime, duration: duration, enabled: resumePosition != nil || retainDuringInterruption)
        }
        captureProgress(flush: true); onDisplayReady?(false)
        statusObserver = nil; playbackObserver = nil; bufferObserver = nil; durationObserver = nil; seekableObserver = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }; timeObserver = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        actualSourceURL = nil
        playing = false; itemReady = false; readyForDisplay = false; waitingForData = true
        resumeApplied = false; resumeInFlight = false
        currentTime = 0; duration = 0; bufferedRanges = []
        seekRanges = []
        holdingRate = false; seekingBase = nil; seekTarget = nil
        if let pinnedURL { MediaCache.shared.unpin(pinnedURL) }; pinnedURL = nil
        if let repairedPinnedURL { MediaCache.shared.unprotectRepairFile(repairedPinnedURL) }; repairedPinnedURL = nil
    }
    private func updatePreloadDemand(waiting: Bool? = nil) {
        guard active, scenePhase == .active, let source = actualSourceURL, !source.isFileURL else {
            MediaCache.shared.removeForegroundVideoDemand(owner: preloadDemandOwner); return
        }
        MediaCache.shared.setForegroundVideoDemand(url: source, owner: preloadDemandOwner,
            waiting: !pausedForOverlay && (waiting ?? preparingVideo))
    }
    private func recordMeasuredFirstFrame() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--qa-continuous59"), active,
              readyForDisplay, itemReady, !awaitingResume, !measuredFirstFrame,
              let started = measuredStartupAt else { return }
        measuredFirstFrame = true
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - started)
        let code: DiagnosticCode = actualSourceKind == .network ? .frameReadyNetwork :
            (actualSourceKind == .cache ? .frameReadyCache : .frameReadyLocal)
        LocalDiagnosticsStore.shared.note(area: .playback, code: code, count: Int(min(elapsed * 1_000, 1_000_000_000)))
        #endif
    }
    private func handleFailure(_ item: AVPlayerItem, notificationError: NSError? = nil) {
        guard active, !pausedForOverlay, player?.currentItem === item, !failureHandled else { return }
        failureHandled = true; playbackFailed = true; playing = false
        let generation = playbackGeneration
        let address = resolvedURL ?? url
        let initial = Self.failure(item, address: address)
        let failedCacheIdentity = actualSourceKind == .cache ? actualSourceURL.flatMap(MediaRepairStore.identity) : nil
        compatibilityAvailable = (initial == .unknown || initial == .decoderMissing) &&
            (Self.isFormatFailure(notificationError) || Self.isFormatFailure(item.error as NSError?))
        let failedRepaired = repairedSource != nil
        let failedTranscoded = repairedSource?.transcoded == true
        if failedRepaired { bypassRepaired = true; repairedSource = nil }
        let eventCodes = item.errorLog().map { Array($0.events.reversed().lazy.map(\.errorStatusCode).filter { $0 != 0 }.prefix(4)) } ?? []
        let diagnostic = PlaybackFailureDiagnostic(workID: diagnosticWorkID, source: actualSourceKind,
            requestedURL: address, sourceURL: actualSourceURL ?? address, recoveryAttempted: recoveryAttempted,
            error: notificationError ?? (item.error as NSError?), eventStatusCodes: eventCodes)
        if case .http(let status) = initial { LocalDiagnosticsStore.shared.note(area: .playback, code: .http, httpStatus: status, playback: diagnostic) }
        else { LocalDiagnosticsStore.shared.note(area: .playback, code: .playbackFailed, count: recoveryAttempted ? 1 : 0, playback: diagnostic) }
        let decision = VideoRecoveryPolicy.decide(failed: true, failure: initial, recoveryAttempted: recoveryAttempted)
        if decision == .manualRetry {
            recovering = false; repairStage = nil; repairProgress = nil
            recoveryMessage = initial == .http(429) ? "请求较多，请稍后重试" : "登录状态需要确认，请重新登录后重试"
            return
        }
        if decision == .skip { confirmUnavailable(); return }
        recovering = true; recoveryMessage = recoveryAttempted ? "正在确认播放状态…" : "正在更新播放地址并重试…"
        recoveryTask = Task {
            defer { if generation == playbackGeneration { recovering = false; repairStage = nil; repairProgress = nil; recoveryTask = nil } }
            if onImageContent != nil && (initial == .unknown || initial == .decoderMissing) {
                // Some site "video" records actually deliver animated GIF/WebP.
                // Probe only this failed, focused item with the image size bound.
                do {
                    _ = try await MediaCache.shared.imageResource(address)
                    guard !Task.isCancelled, active, generation == playbackGeneration else { return }
                    onImageContent?(); return
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, active, generation == playbackGeneration else { return }
                    if Self.blocksFailureAdvance(error) {
                        recoveryMessage = error.localizedDescription
                        return
                    }
                }
            }
            if compatibilityAvailable && automaticVideoRepair && !repairAttempted && !failedTranscoded {
                repairAttempted = true
                do {
                    let result = try await MediaRepair.shared.repair(address, offline: diagnosticOffline, forceTranscode: bypassRepaired, diagnosticWorkID: diagnosticWorkID) { stage, fraction in
                        guard !Task.isCancelled, active, generation == playbackGeneration else { return }
                        repairStage = stage; repairProgress = fraction
                    }
                    guard !Task.isCancelled, active, generation == playbackGeneration else { return }
                    posterRetry += 1
                    recoveryPosition = requestedResume ?? PlaybackResumePolicy.position(position: currentTime, duration: duration)
                    repairedSource = result
                    repairStage = nil; repairProgress = nil; recovering = false
                    playerReprepareEvent = .init(item: ObjectIdentifier(item), generation: generation)
                    return
                } catch is CancellationError { return }
                catch {
                    guard active, generation == playbackGeneration else { return }
                    if actualSourceKind == .cache && decision == .recover {
                        // A failed conversion must not swallow the existing
                        // one-time bypass of a broken disposable browser cache.
                        if case MediaRepairError.damaged = error, let failedCacheIdentity {
                            MediaCache.shared.discardBrokenVideo(address, expected: failedCacheIdentity)
                            repairAttempted = false
                        }
                        repairStage = nil; repairProgress = nil
                    } else {
                        recoveryMessage = (error as? MediaRepairError)?.errorDescription ?? "修复所需文件暂不可用，可重试或尝试兼容播放"
                        if !Self.blocksFailureAdvance(error) { confirmUnavailable() }
                        return
                    }
                }
            }
            if decision == .recover {
                do {
                    try await Task.sleep(for: .seconds(1))
                    let fresh: URL?
                    if let refreshURL { fresh = try await refreshURL() }
                    else { fresh = address }
                    guard !Task.isCancelled, active, generation == playbackGeneration else { return }
                    // A failed retry can move to another work without treating
                    // missing metadata as proof that this work was deleted.
                    guard let fresh else { confirmUnavailable(); return }
                    recoveryPosition = PlaybackResumePolicy.position(position: currentTime, duration: duration)
                    recoveryAttempted = true; resolvedURL = fresh
                    playerReprepareEvent = .init(item: ObjectIdentifier(item), generation: generation)
                } catch {
                    guard !Task.isCancelled, active, generation == playbackGeneration else { return }
                    if Self.blocksFailureAdvance(error) { recoveryMessage = "连接或授权暂不可用，请稍后重试" }
                    else { confirmUnavailable() }
                }
            } else {
                var failure = initial
                if initial == .unknown, !address.isFileURL, let status = await Self.probeStatus(address) { failure = .http(status) }
                guard !Task.isCancelled, active, generation == playbackGeneration else { return }
                if VideoRecoveryPolicy.decide(failed: true, failure: failure, recoveryAttempted: true) == .skip { confirmUnavailable() }
                else { recoveryMessage = "视频暂时无法播放，可稍后重试或手动划到下一条" }
            }
        }
    }
    private func cancelRepair() {
        #if DEBUG && targetEnvironment(simulator)
        if qaPreparationActive { qaPreparationCancelled = true; return }
        #endif
        recoveryTask?.cancel(); recoveryTask = nil; playbackGeneration += 1
        recovering = false; repairStage = nil; repairProgress = nil
        recoveryMessage = "已停止本次修复，原视频已保留"
    }
    private static func isFormatFailure(_ error: NSError?) -> Bool {
        var value = error
        for _ in 0..<5 {
            guard let error = value else { break }
            if error.domain == AVFoundationErrorDomain,
               [AVError.Code.fileFormatNotRecognized.rawValue, AVError.Code.fileFailedToParse.rawValue,
                AVError.Code.decoderNotFound.rawValue].contains(error.code) { return true }
            value = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
    private func openCompatibility() {
        guard active, playbackFailed, compatibilityAvailable else { return }
        stopPosterCapture()
        recoveryTask?.cancel(); recoveryTask = nil; playbackGeneration += 1; recovering = false
        nativeRetrySuspended = true; player?.pause()
        let address = resolvedURL ?? url
        let cached = address.isFileURL ? nil : MediaCache.shared.cached(address, video: true)
        let source = cached ?? address
        let kind: PlaybackDiagnosticSource = cached != nil ? .cache :
            (source.isFileURL ? (diagnosticOffline ? .offline : .local) : .network)
        compatibilityRequest = .init(requestedURL: address, sourceURL: source, sourceKind: kind,
                                     workID: diagnosticWorkID, initialPosition: compatibilityPosition ?? resumePosition)
    }
    private func compatibilityDiagnostic(_ request: CompatibilityRequest, code: Int?) -> PlaybackFailureDiagnostic? {
        PlaybackFailureDiagnostic(workID: request.workID, source: request.sourceKind,
            requestedURL: request.requestedURL, sourceURL: request.sourceURL, recoveryAttempted: true,
            error: code.map { NSError(domain: "WebKitMediaErrorDomain", code: $0) }, eventStatusCodes: [], engine: .webKit)
    }
    private func confirmUnavailable() {
        guard active, !pausedForOverlay else { return }
        recovering = false; recoveryMessage = "视频暂时无法播放"
        onConfirmedUnavailable?()
    }
    private static func blocksFailureAdvance(_ error: Error) -> Bool {
        switch error {
        case ClientError.signedOut, ClientError.accountChanged, ClientError.loadingSite: return true
        case ClientError.http(let status), MediaDownloadError.http(let status): return status == 401 || status == 429
        default: return false
        }
    }
    private static func failure(_ item: AVPlayerItem, address: URL) -> VideoFailure {
        if address.isFileURL, !FileManager.default.fileExists(atPath: address.path) { return .localMissing }
        if let status = item.errorLog()?.events.reversed().map(\.errorStatusCode).first(where: { (400...599).contains($0) }) { return .http(status) }
        var error = item.error as NSError?
        for _ in 0..<5 {
            guard let current = error else { break }
            if current.domain == NSURLErrorDomain { return .network }
            if current.domain == AVFoundationErrorDomain, current.code == AVError.Code.decoderNotFound.rawValue { return .decoderMissing }
            error = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return .unknown
    }
    private static func probeStatus(_ address: URL) async -> Int? {
        guard address.scheme == "https" else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: address); request.httpMethod = "HEAD"
        do { let (_, response) = try await session.data(for: request); return (response as? HTTPURLResponse)?.statusCode }
        catch { return nil }
    }
    private func seek(_ delta: Double, _ phase: MediaPanPhase) {
        if phase == .cancelled { cancelSeek(); return }
        guard canScrub, let player else { return }
        #if DEBUG && targetEnvironment(simulator)
        if phase == .began { qaSeekStartCount += 1 }
        #endif
        if phase == .began { interactiveSeekID = nil; seekingBase = max(0, player.currentTime().seconds); player.pause() }
        guard let base = seekingBase else { return }
        previewSeek(base + delta / 10, phase: phase)
    }
    private func scrub(_ fraction: Double, _ phase: MediaPanPhase) {
        if phase == .cancelled { cancelSeek(); return }
        guard canScrub, let player, let target = VideoSeekMath.time(fraction: fraction, duration: duration) else { return }
        #if DEBUG && targetEnvironment(simulator)
        if phase == .began { qaSeekStartCount += 1 }
        #endif
        if phase == .began { interactiveSeekID = nil; seekingBase = max(0, player.currentTime().seconds); player.pause() }
        guard seekingBase != nil else { return }
        previewSeek(target, phase: phase)
    }
    private func previewSeek(_ requested: Double, phase: MediaPanPhase) {
        guard let target = VideoSeekMath.target(seconds: requested, duration: duration, ranges: seekRanges) else { cancelSeek(); return }
        seekTarget = target
        guard phase == .ended else { return }
        guard let value = player, let item = value.currentItem,
              let plan = VideoSeekMath.interactiveTickPlan(seconds: target, duration: duration, ranges: seekRanges) else { cancelSeek(); return }
        let generation = playbackGeneration
        let operation = UUID()
        seekingBase = nil; seekTarget = nil; interactiveSeekID = operation
        // Browsing seeks allow at most 50ms within one continuous seekable
        // interval. Exact restore remains in applyResume; it has a different contract.
        value.seek(to: CMTime(value: plan.targetTicks, timescale: plan.timescale),
                   toleranceBefore: CMTime(value: plan.toleranceBeforeTicks, timescale: plan.timescale),
                   toleranceAfter: CMTime(value: plan.toleranceAfterTicks, timescale: plan.timescale)) { finished in
            Task { @MainActor in
                #if DEBUG && targetEnvironment(simulator)
                qaSeekEvents.callbacks += 1; qaSeekEvents.lastFinished = finished
                #endif
                guard interactiveSeekID == operation, player === value, value.currentItem === item,
                      generation == playbackGeneration else { return }
                #if DEBUG && targetEnvironment(simulator)
                qaSeekEvents.commits += 1
                #endif
                interactiveSeekID = nil
                if finished {
                    let actual = value.currentTime().seconds
                    if actual.isFinite && actual >= 0 { currentTime = actual; captureProgress(flush: true) }
                    else { LocalDiagnosticsStore.shared.note(area: .playback, code: .seekFailed) }
                }
                else { LocalDiagnosticsStore.shared.note(area: .playback, code: .seekFailed) }
                playerSyncEvent = .init(item: ObjectIdentifier(item), generation: generation)
            }
        }
        // An interactive jump must not wait for a seek completion before accepting
        // play/pause intent. Only exact history restoration owns resumeInFlight.
        syncPlayback()
    }
    private func cancelSeek() {
        seekingBase = nil; seekTarget = nil; syncPlayback()
    }
    private func holdRate(_ held: Bool) {
        #if DEBUG && targetEnvironment(simulator)
        if held { qaRateHoldCount += 1 }
        #endif
        if held { wasPlayingBeforeHold = playing; holdingRate = true }
        else { holdingRate = false; playing = wasPlayingBeforeHold }
        syncPlayback()
    }
    private static func time(_ seconds: Double) -> String { String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
}
