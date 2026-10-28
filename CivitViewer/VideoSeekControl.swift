import Foundation

struct SeekTimeRange: Equatable {
    let start: Double
    let end: Double
}

enum VideoSeekMath {
    struct InteractivePlan: Equatable {
        let target: Double
        let toleranceBefore: Double
        let toleranceAfter: Double
    }

    static func target(seconds: Double, duration: Double, ranges: [SeekTimeRange]) -> Double? {
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return nil }
        let upperBound = max(0, duration - 0.05)
        guard upperBound > 0 else { return nil }
        let valid = ranges.compactMap { range -> SeekTimeRange? in
            guard range.start.isFinite, range.end.isFinite, range.start <= range.end,
                  range.end >= 0, range.start <= upperBound else { return nil }
            let start = min(upperBound, max(0, range.start))
            let end = min(upperBound, max(0, range.end))
            return start <= end ? SeekTimeRange(start: start, end: end) : nil
        }
        guard !valid.isEmpty else { return nil }
        let requested = min(upperBound, max(0, seconds))
        if valid.contains(where: { requested >= $0.start && requested <= $0.end }) { return requested }
        let candidates = valid.flatMap { [$0.start, $0.end] }
        return candidates.min {
            let left = abs($0 - requested), right = abs($1 - requested)
            return left == right ? $0 < $1 : left < right
        }
    }

    static func interactivePlan(seconds: Double, duration: Double, ranges: [SeekTimeRange]) -> InteractivePlan? {
        guard let resolved = target(seconds: seconds, duration: duration, ranges: ranges) else { return nil }
        guard let interval = containingInterval(target: resolved, duration: duration, ranges: ranges) else { return nil }
        return InteractivePlan(target: resolved,
                               toleranceBefore: min(0.05, resolved - interval.start),
                               toleranceAfter: min(0.05, interval.end - resolved))
    }

    struct InteractiveTickPlan: Equatable {
        let targetTicks: Int64
        let toleranceBeforeTicks: Int64
        let toleranceAfterTicks: Int64
        let timescale: Int32
    }

    static func interactiveTickPlan(seconds: Double, duration: Double, ranges: [SeekTimeRange],
                                    timescale: Int32 = 60_000) -> InteractiveTickPlan? {
        guard timescale > 0,
              let resolved = target(seconds: seconds, duration: duration, ranges: ranges),
              let interval = containingInterval(target: resolved, duration: duration, ranges: ranges) else { return nil }
        let scale = Double(timescale)
        let lowerValue = interval.start * scale
        let upperValue = interval.end * scale
        let targetValue = resolved * scale
        let maxTick = Double(Int64.max)
        guard lowerValue.isFinite, upperValue.isFinite, targetValue.isFinite,
              lowerValue >= 0, upperValue < maxTick,
              targetValue >= 0, targetValue < maxTick else { return nil }
        let lowerTick = Int64(ceil(lowerValue))
        let upperTick = Int64(floor(upperValue))
        guard lowerTick <= upperTick else { return nil }
        let roundedTarget = Int64(targetValue.rounded(.toNearestOrAwayFromZero))
        let resolvedTick = min(upperTick, max(lowerTick, roundedTarget))
        let maxToleranceTicks = Int64(floor(0.05 * scale))
        return InteractiveTickPlan(targetTicks: resolvedTick,
                                   toleranceBeforeTicks: min(maxToleranceTicks, resolvedTick - lowerTick),
                                   toleranceAfterTicks: min(maxToleranceTicks, upperTick - resolvedTick),
                                   timescale: timescale)
    }

    private static func containingInterval(target resolved: Double, duration: Double,
                                           ranges: [SeekTimeRange]) -> SeekTimeRange? {
        let upperBound = duration - 0.05
        let intervals = ranges.compactMap { range -> SeekTimeRange? in
            guard range.start.isFinite, range.end.isFinite, range.start <= range.end,
                  range.end >= 0, range.start <= upperBound else { return nil }
            let start = min(upperBound, max(0, range.start))
            let end = min(upperBound, max(0, range.end))
            return start <= end ? SeekTimeRange(start: start, end: end) : nil
        }.sorted { $0.start < $1.start }

        // Merge overlapping or touching ranges: adjacent AV seekable ranges form one
        // continuous interval, while any positive gap remains a hard boundary.
        var containing: SeekTimeRange?
        for interval in intervals {
            if let current = containing, interval.start <= current.end {
                containing = SeekTimeRange(start: current.start, end: max(current.end, interval.end))
            } else {
                if let current = containing, resolved >= current.start, resolved <= current.end { break }
                containing = interval
            }
        }
        guard let interval = containing, resolved >= interval.start, resolved <= interval.end else { return nil }
        return interval
    }

    static func time(fraction: Double, duration: Double) -> Double? {
        guard fraction.isFinite, duration.isFinite, duration > 0 else { return nil }
        let upperBound = max(0, duration - 0.05)
        guard upperBound > 0 else { return nil }
        return min(1, max(0, fraction)) * upperBound
    }

    static func allowsHorizontalDrag(vx: Double, vy: Double) -> Bool {
        guard vx.isFinite, vy.isFinite else { return false }
        return abs(vx) > abs(vy) * 1.2
    }
}

#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import UIKit

struct VideoSeekControl: UIViewRepresentable {
    var position: Double
    var duration: Double
    var buffered: Double
    var enabled: Bool
    var interactionActive: Bool = false
    let onSeek: (Double, MediaPanPhase) -> Void
    var onInteractionChange: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SeekTrackView {
        let view = SeekTrackView(frame: .zero)
        view.isAccessibilityElement = true
        view.accessibilityTraits = .adjustable
        view.addGestureRecognizer(context.coordinator.pan)
        view.addGestureRecognizer(context.coordinator.tap)
        context.coordinator.tap.require(toFail: context.coordinator.pan)
        context.coordinator.pan.delegate = context.coordinator
        context.coordinator.tap.delegate = context.coordinator
        context.coordinator.view = view
        context.coordinator.update(self)
        return view
    }

    func updateUIView(_ view: SeekTrackView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleUIView(_ view: SeekTrackView, coordinator: Coordinator) {
        coordinator.cancelDrag()
        coordinator.view = nil
    }

    final class SeekTrackView: UIControl {
        var positionFraction: CGFloat = 0 { didSet { setNeedsDisplay() } }
        var bufferedFraction: CGFloat = 0 { didSet { setNeedsDisplay() } }
        var emphasized = false { didSet { setNeedsDisplay() } }
        var controlEnabled = true { didSet { isUserInteractionEnabled = controlEnabled; alpha = controlEnabled ? 1 : 0.55 } }
        var durationValue: Double = 0
        var positionValue: Double = 0
        var onAccessibilitySeek: ((Double) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isOpaque = false
            clearsContextBeforeDrawing = true
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            backgroundColor = .clear
            isOpaque = false
            clearsContextBeforeDrawing = true
        }

        override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 44) }
        override func accessibilityIncrement() { accessibilityStep(5) }
        override func accessibilityDecrement() { accessibilityStep(-5) }
        private func accessibilityStep(_ delta: Double) {
            guard controlEnabled, let duration = VideoSeekMath.time(fraction: 1, duration: durationValue) else { return }
            onAccessibilitySeek?(min(duration, max(0, positionValue + delta)))
        }

        override func draw(_ rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext() else { return }
            context.clear(rect)
            let horizontalInset: CGFloat = 6
            let trackHeight: CGFloat = emphasized ? 4 : 2
            // Keep the full 44-point hit area while drawing closer to the author row.
            let trackCenterY = min(bounds.midY, 12)
            let trackRect = CGRect(x: horizontalInset, y: trackCenterY - trackHeight / 2,
                                   width: max(0, bounds.width - horizontalInset * 2), height: trackHeight)
            guard trackRect.width > 0 else { return }
            let trackPath = CGPath(roundedRect: trackRect, cornerWidth: trackHeight / 2,
                                   cornerHeight: trackHeight / 2, transform: nil)
            let baseColor = UIColor.white.withAlphaComponent(emphasized ? 0.72 : 0.58)
            context.setFillColor(baseColor.cgColor)
            context.addPath(trackPath); context.fillPath()
            context.saveGState()
            context.addPath(trackPath); context.clip()
            let bufferedWidth = trackRect.width * min(1, max(0, bufferedFraction))
            if bufferedWidth > 0 {
                let bufferedRect = CGRect(x: trackRect.minX, y: trackRect.minY, width: bufferedWidth, height: trackRect.height)
                context.setFillColor(UIColor.white.withAlphaComponent(0.38).cgColor)
                context.fill(bufferedRect)
            }
            let playedWidth = trackRect.width * min(1, max(0, positionFraction))
            if playedWidth > 0 {
                let playedRect = CGRect(x: trackRect.minX, y: trackRect.minY, width: playedWidth, height: trackRect.height)
                context.setFillColor(UIColor.white.cgColor)
                context.fill(playedRect)
            }
            context.restoreGState()
            if emphasized {
                let centerY = trackRect.midY
                let thumb = CGRect(x: trackRect.minX + playedWidth - 5, y: centerY - 5, width: 10, height: 10)
                context.setFillColor(UIColor.white.cgColor)
                context.fillEllipse(in: thumb)
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private var configuration: VideoSeekControl
        weak var view: SeekTrackView?
        let pan = UIPanGestureRecognizer()
        let tap = UITapGestureRecognizer()
        private var tracking = false
        private var startPosition = 0.0
        private var lastFraction = 0.0

        init(_ configuration: VideoSeekControl) {
            self.configuration = configuration
            super.init()
            pan.addTarget(self, action: #selector(panned(_:)))
            tap.addTarget(self, action: #selector(tapped(_:)))
            pan.maximumNumberOfTouches = 1
            pan.cancelsTouchesInView = false
            tap.cancelsTouchesInView = false
        }

        func update(_ value: VideoSeekControl) {
            configuration = value
            guard let view else { return }
            view.durationValue = value.duration
            view.positionValue = value.position
            view.controlEnabled = value.enabled && value.duration.isFinite && value.duration > 0
            view.emphasized = tracking || value.interactionActive
            if !tracking {
                view.positionFraction = fraction(value.position, duration: value.duration)
            }
            view.bufferedFraction = CGFloat(fraction(value.buffered, duration: value.duration))
            view.accessibilityLabel = "播放进度"
            view.accessibilityValue = "\(Self.clock(value.position)) / \(Self.clock(value.duration))"
            view.onAccessibilitySeek = { [weak self] seconds in
                guard let self, let fraction = VideoSeekMath.time(fraction: seconds / self.configuration.duration, duration: self.configuration.duration) else { return }
                self.beginInteraction()
                self.configuration.onSeek(min(1, fraction / self.configuration.duration), .began)
                self.configuration.onSeek(min(1, fraction / self.configuration.duration), .ended)
                self.endInteraction()
            }
            if !view.controlEnabled { cancelDrag() }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard configuration.enabled, configuration.duration.isFinite, configuration.duration > 0,
                  let view, view.bounds.width > 0 else { return false }
            if gestureRecognizer === pan {
                let velocity = pan.velocity(in: view)
                return VideoSeekMath.allowsHorizontalDrag(vx: Double(velocity.x), vy: Double(velocity.y))
            }
            return gestureRecognizer === tap
        }

        @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
            guard let view, view.bounds.width > 0 else { return }
            switch recognizer.state {
            case .began:
                beginInteraction()
                startPosition = configuration.position
                updateFraction(at: recognizer.location(in: view).x, view: view, phase: .began)
            case .changed:
                updateFraction(at: recognizer.location(in: view).x, view: view, phase: .changed)
            case .ended:
                updateFraction(at: recognizer.location(in: view).x, view: view, phase: .ended)
                endInteraction()
            case .cancelled, .failed:
                cancelDrag()
            default: break
            }
        }

        @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
            guard let view, view.bounds.width > 0 else { return }
            let fraction = touchFraction(recognizer.location(in: view).x, width: view.bounds.width)
            lastFraction = fraction
            beginInteraction()
            configuration.onSeek(fraction, .began)
            configuration.onSeek(fraction, .ended)
            endInteraction()
        }

        func cancelDrag() {
            guard tracking else { return }
            tracking = false
            updateEmphasis()
            lastFraction = fraction(startPosition, duration: configuration.duration)
            view?.positionFraction = CGFloat(lastFraction)
            configuration.onSeek(lastFraction, .cancelled)
            configuration.onInteractionChange?(false)
        }

        private func updateFraction(at x: CGFloat, view: SeekTrackView, phase: MediaPanPhase) {
            let fraction = touchFraction(x, width: view.bounds.width)
            lastFraction = fraction
            view.positionFraction = CGFloat(fraction)
            configuration.onSeek(fraction, phase)
        }

        private func beginInteraction() {
            guard !tracking else { return }
            tracking = true
            updateEmphasis()
            configuration.onInteractionChange?(true)
        }

        private func endInteraction() {
            guard tracking else { return }
            tracking = false
            updateEmphasis()
            configuration.onInteractionChange?(false)
        }

        private func updateEmphasis() {
            view?.emphasized = tracking || configuration.interactionActive
        }

        private func touchFraction(_ x: CGFloat, width: CGFloat) -> Double {
            let adjusted = min(max(x, 6), max(6, width - 6))
            return Double((adjusted - 6) / max(1, width - 12))
        }

        private func fraction(_ value: Double, duration: Double) -> Double {
            guard value.isFinite, duration.isFinite, duration > 0 else { return 0 }
            return min(1, max(0, value / duration))
        }

        private static func clock(_ value: Double) -> String {
            guard value.isFinite, value >= 0 else { return "--:--" }
            let seconds = Int(min(Double(Int.max), value).rounded(.down))
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
    }
}
#endif
