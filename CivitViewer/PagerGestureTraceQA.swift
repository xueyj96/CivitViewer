#if DEBUG && targetEnvironment(simulator)
import UIKit

/// Explicit synthetic QA only. Memory is bounded; encoding occurs on AX read,
/// never in a touch callback. The observer never recognizes or prevents a gesture.
@MainActor final class PagerGestureTraceQA {
    static var enabled: Bool {
        CollectionPagingQA.enabled && ProcessInfo.processInfo.arguments.contains("--qa-pager-touch-trace")
    }
    static weak var active: PagerGestureTraceQA?
    private weak var window: UIWindow?
    private weak var viewport: UIView?
    private weak var scroll: UIScrollView?
    private var observer: PassiveTouches?
    private var probe: Readback?
    private var events: [[String: Any]] = []
    private var sequence = 0
    private var sampledMoves = 0
    private var droppedEvents = 0
    private var lastMove: [String: Double] = [:]
    private var touchSequence = 0
    private var touches: [ObjectIdentifier: Int] = [:]
    var nativeState: () -> [String: Any] = { [:] }

    func attach(viewport: UIView, scroll: UIScrollView, visible: Bool) {
        guard Self.enabled else { return }
        self.viewport = viewport; self.scroll = scroll
        guard visible, let next = viewport.window else { detach(); return }
        Self.active = self
        guard window !== next else { return }
        detach(); window = next; Self.active = self
        let observer = PassiveTouches()
        observer.cancelsTouchesInView = false
        observer.delaysTouchesBegan = false; observer.delaysTouchesEnded = false
        observer.receive = { [weak self] phase, touch, event in self?.recordTouch(phase, touch, event) }
        next.addGestureRecognizer(observer); self.observer = observer
        let probe = Readback(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        probe.read = { [weak self] in self?.json() }
        probe.isUserInteractionEnabled = false; probe.isAccessibilityElement = true
        probe.accessibilityTraits = .staticText
        probe.accessibilityIdentifier = "pager.qa.trace"
        probe.accessibilityLabel = "Native paging touch trace"
        viewport.addSubview(probe); self.probe = probe
        record("trace.attached", [:])
    }

    func detach() {
        if Self.active === self { Self.active = nil }
        if let observer { window?.removeGestureRecognizer(observer) }
        observer = nil; window = nil; probe?.removeFromSuperview(); probe = nil
    }

    func record(_ event: String, _ detail: [String: Any], sampleKey: String? = nil) {
        guard Self.enabled else { return }
        let now = CACurrentMediaTime()
        if let sampleKey {
            if let previous = lastMove[sampleKey], now - previous < 0.05 { sampledMoves += 1; return }
            lastMove[sampleKey] = now
        }
        sequence += 1
        var value = detail
        value["event"] = event; value["sequence"] = sequence; value["uptime"] = now
        value["native"] = snapshot()
        events.append(value)
        if events.count > 2048 { droppedEvents += events.count - 2048; events.removeFirst(events.count - 2048) }
    }

    func pan(_ pan: UIPanGestureRecognizer) {
        record("native.pan", ["state": pan.state.rawValue,
            "translation": point(pan.translation(in: pan.view)),
            "velocity": point(pan.velocity(in: pan.view)),
            "windowLocation": point(pan.location(in: window))],
            sampleKey: pan.state == .changed ? "native.pan.changed" : nil)
    }

    private func recordTouch(_ phase: String, _ touch: UITouch, _ event: UIEvent) {
        guard let window else { return }
        let key = ObjectIdentifier(touch)
        if phase == "began" { touchSequence += 1; touches[key] = touchSequence }
        guard let touchID = touches[key] else { return }
        let location = touch.location(in: window)
        let currentHit = phase == "began" || phase == "ended" ? window.hitTest(location, with: event) : nil
        record("touch.\(phase)", ["touchID": touchID, "touchTimestamp": touch.timestamp,
            "windowLocation": point(location), "previousWindowLocation": point(touch.previousLocation(in: window)),
            "scrollLocation": point(touch.location(in: scroll)),
            "touchView": viewInfo(touch.view), "hitTestAtCurrentPoint": viewInfo(currentHit)],
            sampleKey: phase == "moved" ? "touch.\(touchID).moved" : nil)
        if phase == "ended" || phase == "cancelled" { touches.removeValue(forKey: key) }
    }

    private func snapshot() -> [String: Any] {
        var value = nativeState()
        if let viewport, let window { value["viewportWindow"] = rect(viewport.convert(viewport.bounds, to: window)) }
        if let scroll {
            value["offset"] = point(scroll.contentOffset)
            value["bounds"] = rect(scroll.bounds)
            value["contentSize"] = ["width": Double(scroll.contentSize.width), "height": Double(scroll.contentSize.height)]
            value["panState"] = scroll.panGestureRecognizer.state.rawValue
            value["tracking"] = scroll.isTracking
            value["bounces"] = scroll.bounces
            value["dragging"] = scroll.isDragging; value["decelerating"] = scroll.isDecelerating
            value["scrollEnabled"] = scroll.isScrollEnabled; value["pagingEnabled"] = scroll.isPagingEnabled
        }
        return value
    }

    private func viewInfo(_ view: UIView?) -> [String: Any] {
        guard let view else { return ["present": false] }
        var chain: [String] = []; var candidate: UIView? = view
        var nativeAncestor = false; var controlAncestor = false
        while let current = candidate, chain.count < 12 {
            chain.append(String(describing: type(of: current)))
            nativeAncestor = nativeAncestor || current === scroll
            controlAncestor = controlAncestor || current is UIControl
            candidate = current.superview
        }
        var value: [String: Any] = ["class": String(describing: type(of: view)),
            "ancestors": chain, "ancestorTruncated": candidate != nil,
            "nativeScrollAncestor": nativeAncestor, "controlAncestor": controlAncestor]
        if let window { value["windowFrame"] = rect(view.convert(view.bounds, to: window)) }
        return value
    }

    private func json() -> String? {
        let value: [String: Any] = ["events": events, "lastSequence": sequence, "current": snapshot(),
                                  "sampledMoves": sampledMoves, "droppedEvents": droppedEvents]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private func point(_ p: CGPoint) -> [String: Double] { ["x": Double(p.x), "y": Double(p.y)] }
    private func rect(_ r: CGRect) -> [String: Double] {
        ["x": Double(r.minX), "y": Double(r.minY), "width": Double(r.width), "height": Double(r.height)]
    }
    private final class Readback: UIView {
        var read: (() -> String?)?
        override var accessibilityValue: String? { get { read?() } set {} }
    }
    private final class PassiveTouches: UIGestureRecognizer {
        var receive: ((String, UITouch, UIEvent) -> Void)?
        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { for t in touches { receive?("began", t, event) } }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { for t in touches { receive?("moved", t, event) } }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            for t in touches { receive?("ended", t, event) }; state = .failed
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            for t in touches { receive?("cancelled", t, event) }; state = .failed
        }
    }
}
#endif
