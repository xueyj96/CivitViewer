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

#if DEBUG && targetEnvironment(simulator)
private struct VideoPreparationPresentedKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue()
    }
}
#endif

struct VideoPreparationOverlay: View {
    let visible: Bool
    let detail: String
    let progress: Double?
    let canCancel: Bool
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPresented = false
    #if DEBUG && targetEnvironment(simulator)
    @State private var debugIdentity = UUID()
    #endif

    private var validProgress: Double? {
        guard let progress, progress.isFinite else { return nil }
        return min(max(progress, 0), 1)
    }

    #if DEBUG && targetEnvironment(simulator)
    private var debugProgressValue: String {
        validProgress.map { String($0) } ?? "unknown"
    }
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ProgressView().tint(.white.opacity(0.8)).controlSize(.small).accessibilityHidden(true)
                Text(detail)
                    .font(.caption).foregroundStyle(.white.opacity(0.9))
                    .lineLimit(canCancel ? 2 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("media.preparation.detail")
                if canCancel {
                    Button(action: onCancel) {
                        Text("取消").font(.caption.weight(.medium)).foregroundStyle(.white)
                            .lineLimit(1).fixedSize()
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!isPresented || !visible)
                    .accessibilityIdentifier("media.preparation.cancel")
                }
            }
            if let validProgress {
                ProgressView(value: validProgress).tint(.white.opacity(0.8)).frame(height: 3)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, canCancel ? 6 : 7)
        .frame(maxWidth: 272, alignment: .leading)
        .background(Color.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .anchorPreference(key: VideoPreparationGestureAnchorKey.self, value: .bounds) { anchor in
            isPresented && visible && canCancel ? anchor : nil
        }
        .opacity(isPresented ? 1 : 0)
        .allowsHitTesting(isPresented && visible && canCancel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("media.preparation")
        #if DEBUG && targetEnvironment(simulator)
        .accessibilityValue("id=\(debugIdentity.uuidString);visible=\(isPresented ? 1 : 0);progress=\(debugProgressValue)")
        .preference(key: VideoPreparationPresentedKey.self, value: isPresented)
        #endif
        .accessibilityHidden(!isPresented)
        .task(id: visible) {
            if visible {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                    isPresented = true
                }
            } else {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                    isPresented = false
                }
            }
        }
        .onDisappear { isPresented = false }
    }
}

// Put waiting feedback above the existing social/progress controls. The frame
// anchor stays on the small bar, so only repair actions exclude media gestures.
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

    private var detail: String {
        switch stage {
        case .native: "正在加载原生播放器"
        case .repair: "正在转换视频格式"
        case .newPlayer: "正在准备兼容播放器"
        case .hidden: ""
        }
    }

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
                VideoPreparationOverlay(
                    visible: stage != .hidden,
                    detail: detail,
                    progress: progress,
                    canCancel: stage == .repair,
                    onCancel: { cancelCount += 1; stage = .hidden }
                )
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
                    bottomExclusion: 80,
                    excludedFrames: gestureFrame.isEmpty ? [] : [gestureFrame],
                    onTap: { tapCount += 1 },
                    onChromeHold: { chromeHoldCount += 1 }
                )
            }
        }
    }
}
#endif
