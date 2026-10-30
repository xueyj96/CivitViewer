import Foundation
import SwiftUI

enum VideoPreparationGestureSpace {
    static let name = "video-preparation-gesture-space"
}

struct VideoPreparationGestureFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty || value.isEmpty { value = next }
    }
}

struct VideoPreparationGestureAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if let next = nextValue() { value = next }
    }
}

func resolvedVideoPreparationFrame(_ anchor: Anchor<CGRect>?, in geometry: GeometryProxy) -> CGRect {
    guard let anchor else { return .zero }
    // The resolving GeometryReader shares the named host's bounds, so this is
    // already the local rectangle consumed by MediaGestureLayer.
    return geometry[anchor]
}

struct VideoPreparationPresentedKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue()
    }
}

/// Only the focused video's inability to play drives this passive indicator.
struct VideoWaitingIndicator: View {
    let visible: Bool
    @State private var isPresented = false

    var body: some View {
        ZStack {
            Color.clear.accessibilityHidden(true)
            if visible && isPresented {
                ProgressView().tint(.white).controlSize(.small).dynamicTypeSize(.medium)
                    .accessibilityLabel("视频正在缓冲")
                    .accessibilityIdentifier("media.waiting")
            }
        }
            .frame(width: 20, height: 20)
            .allowsHitTesting(false)
            .task(id: visible) {
                isPresented = false
                guard visible else { return }
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, visible else { return }
                isPresented = true
            }
            .onDisappear { isPresented = false }
    }
}

struct VideoPreparationOverlay: View {
    let visible: Bool
    let progress: Double?
    let canCancel: Bool
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPresented = false
    @State private var presentedAt: ContinuousClock.Instant?
    @State private var displayedProgress: Double?
    #if DEBUG && targetEnvironment(simulator)
    @State private var debugIdentity = UUID()
    #endif

    private var validProgress: Double? {
        guard let progress, progress.isFinite else { return nil }
        return min(max(progress, 0), 1)
    }

    #if DEBUG && targetEnvironment(simulator)
    private var debugProgressValue: String {
        displayedProgress.map { String($0) } ?? "unknown"
    }
    #endif

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if let displayedProgress {
                Text("\(Int(displayedProgress * 100))%")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.9))
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("视频准备进度")
                    .accessibilityValue("\(Int(displayedProgress * 100))%")
                    .accessibilityIdentifier("media.preparation.progress")
            } else {
                Spacer(minLength: 0)
            }
            if canCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44, alignment: .bottom).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("取消视频修复")
                .disabled(!isPresented || !visible)
                .anchorPreference(key: VideoPreparationGestureAnchorKey.self, value: .bounds) { anchor in
                    isPresented && visible ? anchor : nil
                }
                .accessibilityIdentifier("media.preparation.cancel")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44, alignment: .bottomLeading)
        .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
        .opacity(isPresented ? 1 : 0)
        .allowsHitTesting(isPresented && visible && canCancel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("media.preparation")
        .preference(key: VideoPreparationPresentedKey.self, value: isPresented)
        #if DEBUG && targetEnvironment(simulator)
        .accessibilityValue("id=\(debugIdentity.uuidString);visible=\(isPresented ? 1 : 0);progress=\(debugProgressValue)")
        #endif
        .accessibilityHidden(!isPresented)
        .task(id: visible) {
            if visible {
                displayedProgress = validProgress
                guard !isPresented else { return }
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                presentedAt = .now
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                    isPresented = true
                }
            } else {
                guard isPresented else { return }
                let elapsed = presentedAt.map { $0.duration(to: .now) } ?? .zero
                // Keep the inline progress stable through brief repair changes;
                // this never delays the player or changes its surface geometry.
                try? await Task.sleep(for: max(.milliseconds(180), .milliseconds(650) - elapsed))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                    isPresented = false
                }
                presentedAt = nil
            }
        }
        .onChange(of: validProgress) { _, value in if visible { displayedProgress = value } }
        .onDisappear { isPresented = false; presentedAt = nil }
    }
}

// The production status is inside VideoProgressChrome's existing 44pt band.
// This placement helper is retained for the isolated native-control QA host.
extension View {
    func videoPreparationPlacement(bottomClearance: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 0) { self; Spacer(minLength: 0) }
                // Reserve the right-side 44pt action column and a 12pt gap.
                .padding(.leading, 20).padding(.trailing, 76).padding(.bottom, bottomClearance)
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
struct VideoPreparationOverlayQAView: View {
    private enum Stage: Equatable {
        case native
        case repair
        case newPlayer
        case hidden
    }

    @State private var stage: Stage = .native
    @State private var cancelCount = 0
    @State private var tapCount = 0
    @State private var chromeHoldCount = 0
    @State private var gestureFrame: CGRect = .zero
    @State private var panelPresented = false

    private var progress: Double? {
        stage == .repair ? 0.65 : nil
    }

    private var qaValue: String {
        "stage=\(stageName);visible=\(stage == .hidden ? 0 : 1);presented=\(panelPresented ? 1 : 0);cancelCount=\(cancelCount);tapCount=\(tapCount);chromeHoldCount=\(chromeHoldCount);panel=\(Int(gestureFrame.minX)),\(Int(gestureFrame.minY)),\(Int(gestureFrame.width)),\(Int(gestureFrame.height))"
    }

    private var stageName: String {
        switch stage {
        case .native: "native"
        case .repair: "repair"
        case .newPlayer: "player"
        case .hidden: "hidden"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.gray.opacity(0.25)
                VideoWaitingIndicator(visible: stage != .hidden)
                VideoProgressChrome(position: 3, duration: 30, bufferedRanges: [.init(start: 0, end: 12)],
                    enabled: false, emphasized: false, showTimes: false,
                    onSeek: { _, _ in }, onInteractionChange: { _ in },
                    preparationVisible: stage == .repair,
                    preparationProgress: progress, preparationCanCancel: stage == .repair,
                    onPreparationCancel: { cancelCount += 1; stage = .hidden })
                .videoPreparationPlacement(bottomClearance: 130)

                VStack {
                    Text(qaValue)
                        .font(.system(size: 1))
                        .frame(width: 1, height: 1)
                        .accessibilityIdentifier("media.qa.preparation48")
                        .accessibilityValue(qaValue)
                    Spacer()
                    HStack(spacing: 12) {
                        Button("原生加载") { stage = .native }
                        Button("修复 65%") { stage = .repair }
                        Button("新播放器") { stage = .newPlayer }
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 18)
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
            .onPreferenceChange(VideoPreparationGestureFrameKey.self) { gestureFrame = $0 }
            .onPreferenceChange(VideoPreparationPresentedKey.self) { panelPresented = $0 }
            .background {
                MediaGestureLayer(
                    active: true,
                    isVideo: true,
                    topExclusion: 0,
                    bottomExclusion: 174,
                    excludedFrames: gestureFrame.isEmpty ? [] : [gestureFrame],
                    onTap: { tapCount += 1 },
                    onChromeHold: { chromeHoldCount += 1 }
                )
            }
        }
    }
}
#endif
