import SwiftUI
import UIKit

/// Native bitmap playback. Only the focused page holds animation frames; grid
/// previews keep using a single still and never create animation/player fleets.
struct BitmapMediaSurface: View {
    let url: URL
    let active: Bool
    var gestureTopExclusion: CGFloat = 110
    var gestureExcludedFrames: [CGRect] = []
    var pausedForOverlay = false
    var onReady: ((Bool) -> Void)? = nil
    var onVideoContent: (() -> Void)? = nil
    var onKindSwipe: ((Int) -> Void)? = nil
    var onKindDrag: ((Double, MediaPanPhase) -> Void)? = nil
    var onDoubleTap: (() -> Void)? = nil
    @AppStorage("autoplay") private var autoplay = true
    @State private var resource: CachedImageResource?
    @State private var frames: [UIImage] = []
    @State private var duration = 0.0
    @State private var failure: String?
    @State private var retry = 0
    @State private var playing = true
    private struct Key: Equatable { let url: URL; let retry: Int }
    private struct AnimationKey: Equatable { let file: URL?; let active: Bool }
    @State private var activeRequest: Key?
    @State private var activeAnimation: AnimationKey?
    var body: some View {
        ZStack {
            if let resource {
                AnimatedBitmapView(preview: resource.preview, frames: frames, duration: duration,
                                   playing: active && playing && !pausedForOverlay)
                if resource.frameCount > 1 && active && !playing && failure == nil {
                    Image(systemName: "play.fill").font(.title).foregroundStyle(.white)
                        .frame(width: 64, height: 64).background(.black.opacity(0.35), in: Circle()).allowsHitTesting(false)
                }
            } else if failure == nil { ProgressView().tint(.white) }
            if let failure {
                VStack(spacing: 10) {
                    Text(failure).font(.caption).multilineTextAlignment(.center)
                    Button("重试") { retry += 1 }
                }.padding(14).foregroundStyle(.white).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .task(id: Key(url: url, retry: retry)) {
            let key = Key(url: url, retry: retry)
            guard !Task.isCancelled else { return }
            activeRequest = key
            resource = nil; frames = []; failure = nil; onReady?(false)
            do {
                let value = try await MediaCache.shared.imageResource(key.url)
                try Task.checkCancellation()
                guard activeRequest == key else { return }
                resource = value; onReady?(true)
            } catch is CancellationError {} catch MediaDownloadError.videoContent {
                guard !Task.isCancelled, activeRequest == key else { return }; onVideoContent?()
            } catch {
                guard !Task.isCancelled, activeRequest == key else { return }
                failure = (error as? LocalizedError)?.errorDescription ?? "图片暂时无法加载"
            }
        }
        .task(id: AnimationKey(file: resource?.file, active: active)) {
            let key = AnimationKey(file: resource?.file, active: active)
            guard !Task.isCancelled else { return }
            activeAnimation = key
            frames = []; duration = 0
            guard key.active, let resource, resource.frameCount > 1, let file = key.file else { return }
            do {
                let animation = try await BitmapAnimationQueue.shared.load(file)
                try Task.checkCancellation()
                guard activeAnimation == key else { return }
                frames = animation.frames.map { UIImage(cgImage: $0) }; duration = animation.duration
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, activeAnimation == key else { return }
                failure = (error as? LocalizedError)?.errorDescription ?? "动图暂时无法播放"
            }
        }
        .onAppear { playing = autoplay }
        .onChange(of: active) { _, value in if value { playing = autoplay } }
        .onChange(of: autoplay) { _, value in playing = value }
        .background {
            MediaGestureLayer(active: active, isVideo: false, topExclusion: gestureTopExclusion, excludedFrames: gestureExcludedFrames, onKindSwipe: onKindSwipe,
                              onKindDrag: onKindDrag, onTap: (resource?.frameCount ?? 0) > 1 ? { playing.toggle() } : nil,
                              onDoubleTap: onDoubleTap)
        }
        .onDisappear { activeRequest = nil; activeAnimation = nil; frames = []; resource = nil; onReady?(false) }
    }
}

@MainActor private final class BitmapAnimationQueue {
    static let shared = BitmapAnimationQueue()
    private let queue = MediaLoadQueue(limit: 1, maximumWaiting: 2)
    func load(_ file: URL) async throws -> MediaImageDecoder.Animation {
        let id = UUID(); try await queue.acquire(id); defer { queue.release(id) }
        let job = Task.detached(priority: .userInitiated) { try MediaImageDecoder.animation(file) }
        return try await withTaskCancellationHandler {
            let value = try await job.value; try Task.checkCancellation(); return value
        } onCancel: { job.cancel() }
    }
}

private struct AnimatedBitmapView: UIViewRepresentable {
    let preview: UIImage
    let frames: [UIImage]
    let duration: Double
    let playing: Bool
    final class Host: UIView {
        let imageView = UIImageView()
        override init(frame: CGRect) { super.init(frame: frame); addSubview(imageView) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() { super.layoutSubviews(); imageView.frame = bounds }
    }
    func makeUIView(context: Context) -> Host {
        let host = Host(); let view = host.imageView; view.contentMode = .scaleAspectFit
        view.clipsToBounds = true; view.backgroundColor = .clear; view.isOpaque = false
        view.accessibilityIdentifier = "bitmap-media"
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return host
    }
    func updateUIView(_ host: Host, context: Context) {
        let view = host.imageView
        let changed = view.animationImages?.first !== frames.first || view.animationImages?.count != frames.count
        if changed {
            view.stopAnimating(); view.animationImages = frames.isEmpty ? nil : frames
            view.animationDuration = duration; view.animationRepeatCount = 0
        }
        view.image = preview
        if playing && !frames.isEmpty { if !view.isAnimating { view.startAnimating() } }
        else { view.stopAnimating() }
    }
    static func dismantleUIView(_ host: Host, coordinator: ()) {
        let view = host.imageView
        view.stopAnimating(); view.animationImages = nil; view.image = nil
    }
}

struct CachedPoster: View {
    let source: URL
    let declared: URL?
    var active = false
    var fit = false
    var retryToken = 0
    var allowLocalExtraction = false
    var diagnosticWorkID: Int? = nil
    var onFailure: ((Bool) -> Void)? = nil
    @State private var image: UIImage?
    @State private var failed = false
    @State private var cacheRevision = 0
    private struct Key: Equatable { let source: URL; let declared: URL?; let active: Bool; let local: Bool; let retry: Int; let workID: Int?; let cacheRevision: Int }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: fit ? .fit : .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else if failed {
                    Image(systemName: "play.rectangle").font(.title).foregroundStyle(.secondary)
                        .accessibilityLabel("视频封面暂不可用，打开作品播放")
                } else { ProgressView() }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .task(id: Key(source: source, declared: declared, active: active, local: allowLocalExtraction, retry: retryToken, workID: diagnosticWorkID, cacheRevision: cacheRevision)) {
            guard !Task.isCancelled else { return }
            image = nil; failed = false; onFailure?(false)
            var stage = PosterDiagnosticStage.cachedPoster
            notePoster(.posterStarted, error: nil, stage: stage)
            do {
                // The focused native player supplies its current frame. A still
                // preview must not start a second original-video download.
                let value = try await MediaCache.shared.loadPoster(source: source, declared: declared, allowExtraction: false,
                    allowLocalExtraction: allowLocalExtraction, onStage: { stage = $0 })
                try Task.checkCancellation(); image = value
                notePoster(.posterLoaded, error: nil, stage: stage)
            } catch is CancellationError {
                notePoster(.posterCancelled, error: nil, stage: stage)
            } catch {
                if Task.isCancelled { notePoster(.posterCancelled, error: nil, stage: stage); return }
                failed = true; onFailure?(true)
                notePoster(.posterFailed, error: error, stage: stage)
            }
        }
        .onReceive(MediaCache.shared.posterUpdates) { key in
            guard key == MediaCache.shared.posterCacheKey(for: source) else { return }
            cacheRevision += 1
        }
        .onDisappear { image = nil }
        #if DEBUG && targetEnvironment(simulator)
        .overlay(alignment: .topLeading) {
            if CollectionPagingQA.enabled, let diagnosticWorkID {
                let value = "state=\(image == nil ? (failed ? "failed" : "pending") : "ready");width=\(Int(image?.size.width ?? 0));height=\(Int(image?.size.height ?? 0))"
                Text(value).font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                    .accessibilityIdentifier("poster.qa.\(diagnosticWorkID)").accessibilityValue(value)
            }
        }
        #endif
    }
    private func notePoster(_ code: DiagnosticCode, error: Error?, stage: PosterDiagnosticStage) {
        let status: Int?
        if case .http(let value)? = error as? MediaDownloadError { status = value } else { status = nil }
        let context = PlaybackFailureDiagnostic(workID: diagnosticWorkID, source: source.isFileURL ? .local : .network,
            requestedURL: declared ?? source, sourceURL: source, recoveryAttempted: retryToken > 0,
            error: error.map { $0 as NSError }, eventStatusCodes: status.map { [$0] } ?? [],
            posterStage: stage, posterFailure: error.map { PosterDiagnosticPolicy.failure($0, stage: stage) })
        guard let context else { return }
        LocalDiagnosticsStore.shared.note(area: .thumbnail, code: code, httpStatus: status, playback: context)
    }
}
