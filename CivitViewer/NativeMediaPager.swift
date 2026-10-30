import SwiftUI
import UIKit

/// One native vertical paging viewport. The renderer remains the ordinary SwiftUI
/// media page; UIKit owns only page settlement and the bounded controller cache.
struct NativeMediaPager: View {
    let ids: [Int]
    @Binding var focused: Int?
    let initialID: Int?
    let focusRequest: Int
    let queueRevision: Int
    let viewport: CGSize
    let accessibilityIdentifier: String
    var isVisible = true
    var onUserPageSettled: ((Int) -> Void)? = nil
    var onUserContinuationDemand: ((Int) -> Void)? = nil
    var onUserBoundaryDemand: ((Int) -> Void)? = nil
    var boundaryWaiting = false
    var onUserBoundaryCancel: (() -> Void)? = nil
    var onPageDisplayed: ((Int) -> Void)? = nil
    let renderPage: (Int, Bool) -> AnyView
    #if DEBUG && targetEnvironment(simulator)
    @StateObject private var frames = NativePagerFrameBridge()
    #endif

    var body: some View {
        #if DEBUG && targetEnvironment(simulator)
        NativeMediaPagerController(ids: ids, focused: $focused, initialID: initialID, focusRequest: focusRequest,
            queueRevision: queueRevision, viewport: viewport, accessibilityIdentifier: accessibilityIdentifier,
            isVisible: isVisible, onUserPageSettled: onUserPageSettled, onUserContinuationDemand: onUserContinuationDemand, onUserBoundaryDemand: onUserBoundaryDemand, boundaryWaiting: boundaryWaiting, onUserBoundaryCancel: onUserBoundaryCancel, onPageDisplayed: onPageDisplayed, renderPage: renderPage, frames: frames)
            .preference(key: CollectionPagingQAFrameKey.self, value: frames.collection)
            .preference(key: ResumePromptQAFrameKey.self, value: frames.resume)
            .preference(key: PlaybackLayoutQAFrameKey.self, value: frames.playback)
        #else
        NativeMediaPagerController(ids: ids, focused: $focused, initialID: initialID, focusRequest: focusRequest,
            queueRevision: queueRevision, viewport: viewport, accessibilityIdentifier: accessibilityIdentifier,
            isVisible: isVisible, onUserPageSettled: onUserPageSettled, onUserContinuationDemand: onUserContinuationDemand, onUserBoundaryDemand: onUserBoundaryDemand, boundaryWaiting: boundaryWaiting, onUserBoundaryCancel: onUserBoundaryCancel, onPageDisplayed: onPageDisplayed, renderPage: renderPage)
        #endif
    }
}

private struct NativeMediaPagerController: UIViewControllerRepresentable {
    let ids: [Int]
    @Binding var focused: Int?
    let initialID: Int?
    let focusRequest: Int
    let queueRevision: Int
    let viewport: CGSize
    let accessibilityIdentifier: String
    var isVisible = true
    var onUserPageSettled: ((Int) -> Void)? = nil
    var onUserContinuationDemand: ((Int) -> Void)? = nil
    var onUserBoundaryDemand: ((Int) -> Void)? = nil
    var boundaryWaiting = false
    var onUserBoundaryCancel: (() -> Void)? = nil
    var onPageDisplayed: ((Int) -> Void)? = nil
    let renderPage: (Int, Bool) -> AnyView
    #if DEBUG && targetEnvironment(simulator)
    let frames: NativePagerFrameBridge
    #endif

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> NativePagerContainerController {
        let container = NativePagerContainerController()
        context.coordinator.container = container
        container.onLayout = { [weak coordinator = context.coordinator] in coordinator?.layoutChanged() }
        context.coordinator.receive(self)
        return container
    }
    func updateUIViewController(_ container: NativePagerContainerController, context: Context) {
        context.coordinator.receive(self)
    }
    static func dismantleUIViewController(_ container: NativePagerContainerController, coordinator: Coordinator) {
        container.onLayout = nil
        coordinator.dismantle()
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
        struct PageKey: Hashable { let id: Int; let revision: Int }
        struct Transition {
            let focused: Int?
            let request: Int
            let revision: Int
        }
        var configuration: NativeMediaPagerController
        weak var container: NativePagerContainerController?
        weak var controller: NativePageController?
        private var nativeQueueRevision = 0
        var hosts: [PageKey: NativePageHost] = [:]
        private var ids: [Int] = []
        private var revision: Int?
        private var currentID: Int?
        private var transition: Transition?
        private var pending: NativeMediaPagerController?
        private var pendingApplyTask: Task<Void, Never>?
        private var generation = 0
        private var isVisible = true
        private var activeAccessibilityIdentifier = ""
        private weak var observedBoundaryPan: UIPanGestureRecognizer?
        private var boundaryGate: UIPanGestureRecognizer?
        #if DEBUG && targetEnvironment(simulator)
        private let debugInstanceID = UUID().uuidString
        private var debugLastState: Data?
        private var debugLastWrite = -Double.infinity
        private var debugSnapshotWork: DispatchWorkItem?
        private var debugLastEvent = "initial"
        private var debugNavigationOperations: [[String: Any]] = []
        private var touchTrace: PagerGestureTraceQA?
        #endif

        init(_ configuration: NativeMediaPagerController) { self.configuration = configuration }

        func receive(_ value: NativeMediaPagerController) {
            generation &+= 1
            // Visibility is immediate even while page-list changes wait for a
            // transition callback. Hiding the view itself would lose that callback.
            isVisible = value.isVisible
            activeAccessibilityIdentifier = value.accessibilityIdentifier
            container?.view.accessibilityElementsHidden = !isVisible
            container?.view.isUserInteractionEnabled = isVisible
            controller?.view.accessibilityElementsHidden = !isVisible
            controller?.view.isUserInteractionEnabled = isVisible
            #if DEBUG && targetEnvironment(simulator)
            value.frames.isVisible = isVisible
            #endif
            configureScrollView()
            #if DEBUG && targetEnvironment(simulator)
            debugSnapshot(event: "receive")
            #endif
            // Dragging beyond the last page has no willTransition callback.
            // Replacing its neighbors while that drag/bounce still owns the
            // scroll offset cancels the gesture. Defer native queue changes
            // through both native transitions and boundary scrolling.
            if transition != nil || nativeScrollIsMoving {
                #if DEBUG && targetEnvironment(simulator)
                if pending?.ids != value.ids { touchTrace?.record("native.deferQueue", ["incomingCount": value.ids.count]) }
                #endif
                pending = value
                // Updating SwiftUI state is safe during a native transition; replacing
                // UIPageViewController's controller list is deferred until it settles.
                refreshHosts(using: value)
                schedulePendingApply()
                return
            }
            cancelPendingApply()
            pending = nil
            apply(value)
        }

        private var nativeScrollIsMoving: Bool {
            guard let scroll = controller?.viewIfLoaded?.subviews.compactMap({ $0 as? UIScrollView }).first else { return false }
            return boundaryGate?.state == .began || boundaryGate?.state == .changed ||
                scroll.isTracking || scroll.isDragging || scroll.isDecelerating ||
                scroll.panGestureRecognizer.state == .began || scroll.panGestureRecognizer.state == .changed
        }

        private func cancelPendingApply() {
            pendingApplyTask?.cancel()
            pendingApplyTask = nil
        }

        /// One cancellable waiter owns only the latest configuration. Native
        /// transition completion still settles focus; this handles tail bounce,
        /// which does not produce a page-controller transition callback.
        private func schedulePendingApply() {
            guard pending != nil, transition == nil, pendingApplyTask == nil else { return }
            pendingApplyTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.pendingApplyTask = nil
                guard self.transition == nil, let latest = self.pending else { return }
                if self.nativeScrollIsMoving { self.schedulePendingApply(); return }
                self.pending = nil
                self.apply(latest)
            }
        }

        private func apply(_ value: NativeMediaPagerController, settledID: Int? = nil) {
            guard container != nil else { return }
            configuration = value
            let first = revision == nil
            let changedQueue = ids != value.ids || revision != value.queueRevision
            let target: Int?
            if first {
                target = [value.initialID, value.focused, value.ids.first].compactMap { $0 }.first(where: value.ids.contains)
            } else {
                target = [settledID, value.focused, currentID, value.ids.first].compactMap { $0 }.first(where: value.ids.contains)
            }
            ids = value.ids; revision = value.queueRevision; currentID = target
            refreshHosts(using: value)
            if let target {
                let host = host(for: target)
                if controller?.viewControllers?.first !== host {
                    replaceNativeQueue(with: host)
                } else if changedQueue, let controller {
                    // Append/filter/reorder around the same displayed host only
                    // refreshes neighbor ordering. Keep its parent and appearance
                    // lifecycle intact so active playback does not release/reprepare.
                    #if DEBUG && targetEnvironment(simulator)
                    touchTrace?.record("native.beforeNeighborRefresh", ["queueCount": ids.count])
                    #endif
                    controller.dataSource = nil
                    controller.dataSource = self
                    controller.setViewControllers([host], direction: .forward, animated: false)
                    #if DEBUG && targetEnvironment(simulator)
                    debugNavigationOperation("same-host-neighbors-refreshed", target: target)
                    #endif
                }
            } else if controller != nil {
                // An empty SwiftUI queue owns no native page controller. Scroll-style
                // UIPageViewController rejects an empty displayed-controller list.
                removeNativeQueue()
            }
            trimHosts()
            configureScrollView()
            publishFocus(target)
            layoutChanged()
            notifyDisplayed(target)
            #if DEBUG && targetEnvironment(simulator)
            debugSnapshot(event: "apply")
            #endif
        }

        private func removeNativeQueue() {
            if let boundaryGate { boundaryGate.view?.removeGestureRecognizer(boundaryGate) }
            boundaryGate = nil
            observedBoundaryPan?.removeTarget(self, action: #selector(boundaryPanEnded(_:)))
            observedBoundaryPan = nil
            container?.removePageController(preservingHosts: Array(hosts.values))
            controller = nil
        }

        private func replaceNativeQueue(with host: NativePageHost) {
            guard let container else { return }
            #if DEBUG && targetEnvironment(simulator)
            debugNavigationOperation("before-native-queue-replacement", target: host.id)
            #endif
            // Ordinary gestures and same-host neighbor updates retain their pager.
            // A different displayed host gets a fresh native queue, preserving the
            // hosting controllers instead of reusing UIKit's stale three-slot layout.
            removeNativeQueue()
            let next = NativePageController(transitionStyle: .scroll, navigationOrientation: .vertical)
            controller = next
            nativeQueueRevision += 1
            next.view.backgroundColor = .black
            next.view.clipsToBounds = true
            next.view.frame = container.view.bounds
            next.view.accessibilityElementsHidden = !isVisible
            next.view.isUserInteractionEnabled = isVisible
            next.dataSource = self
            next.delegate = self
            next.onLayout = { [weak self] in self?.layoutChanged() }
            // The retained host has been detached using standard child containment.
            // Seed exactly one controller before the new pager enters the window.
            next.setViewControllers([host], direction: .forward, animated: false)
            container.installPageController(next)
            configureScrollView()
            #if DEBUG && targetEnvironment(simulator)
            debugNavigationOperation("after-native-queue-replacement", target: host.id)
            DispatchQueue.main.async { [weak self] in
                self?.debugNavigationOperation("navigation-next-main", target: host.id)
            }
            #endif
        }

        func dismantle() {
            cancelPendingApply()
            transition = nil; pending = nil
            removeNativeQueue()
            hosts.removeAll()
            #if DEBUG && targetEnvironment(simulator)
            debugSnapshotWork?.cancel(); debugSnapshotWork = nil
            configuration.frames.clear()
            touchTrace?.detach(); touchTrace = nil
            #endif
        }

        private func publishFocus(_ id: Int?) {
            guard configuration.focused != id else { return }
            let expectedGeneration = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == expectedGeneration, self.currentID == id, self.transition == nil else { return }
                self.configuration.focused = id
            }
        }

        private func notifyDisplayed(_ id: Int?) {
            guard let id else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isVisible, self.transition == nil, !self.nativeScrollIsMoving,
                      self.currentID == id,
                      let host = self.controller?.viewControllers?.first as? NativePageHost,
                      host.id == id, host.viewIfLoaded?.window != nil else { return }
                self.configuration.onPageDisplayed?(id)
            }
        }

        private func content(for id: Int, using value: NativeMediaPagerController) -> AnyView {
            let content = value.renderPage(id, id == currentID)
                .frame(width: value.viewport.width, height: value.viewport.height)
                .clipped()
            #if DEBUG && targetEnvironment(simulator)
            return AnyView(NativePagerQAContent(content: AnyView(content), id: id, bridge: value.frames))
            #else
            return AnyView(content)
            #endif
        }

        private func host(for id: Int) -> NativePageHost {
            let key = PageKey(id: id, revision: configuration.queueRevision)
            if let existing = hosts[key] { return existing }
            let host = NativePageHost(id: id, rootView: content(for: id, using: configuration))
            host.view.backgroundColor = .black
            host.view.clipsToBounds = true
            host.view.accessibilityElementsHidden = configuration.boundaryWaiting
            host.view.isUserInteractionEnabled = !configuration.boundaryWaiting
            // The parent GeometryReader has already selected the safe-area viewport.
            // A nested hosting root must not subtract those insets a second time.
            host.safeAreaRegions = []
            hosts[key] = host
            #if DEBUG && targetEnvironment(simulator)
            configuration.frames.register(host, id: id)
            #endif
            return host
        }

        private func refreshHosts(using value: NativeMediaPagerController) {
            for (key, host) in hosts where value.ids.contains(key.id) {
                // UIKit owns this hosting root. Suppress its old controls at the
                // native boundary as well as inside the SwiftUI waiting canvas.
                host.view.accessibilityElementsHidden = value.boundaryWaiting
                host.view.isUserInteractionEnabled = !value.boundaryWaiting
                host.rootView = content(for: key.id, using: value)
            }
        }

        private func trimHosts() {
            var retained = Set<Int>()
            if let currentID, let index = ids.firstIndex(of: currentID) {
                for neighbor in max(0, index - 1)...min(ids.count - 1, index + 1) { retained.insert(ids[neighbor]) }
            }
            let displayed = Set((controller?.viewControllers ?? []).compactMap { ($0 as? NativePageHost)?.id })
            hosts = hosts.filter { $0.key.revision == configuration.queueRevision && (retained.contains($0.key.id) || displayed.contains($0.key.id)) }
            #if DEBUG && targetEnvironment(simulator)
            configuration.frames.retain(ids: Set(hosts.keys.map(\.id)))
            #endif
        }

        private func configureScrollView() {
            guard let scroll = controller?.view.subviews.compactMap({ $0 as? UIScrollView }).first else { return }
            if observedBoundaryPan !== scroll.panGestureRecognizer {
                if let boundaryGate { boundaryGate.view?.removeGestureRecognizer(boundaryGate) }
                boundaryGate = nil
                observedBoundaryPan?.removeTarget(self, action: #selector(boundaryPanEnded(_:)))
                observedBoundaryPan = scroll.panGestureRecognizer
                scroll.panGestureRecognizer.addTarget(self, action: #selector(boundaryPanEnded(_:)))
                #if DEBUG && targetEnvironment(simulator)
                let installGate = !ProcessInfo.processInfo.arguments.contains("--qa-disable-boundary-gate65")
                #else
                let installGate = true
                #endif
                if installGate {
                    let gate = UIPanGestureRecognizer(target: self, action: #selector(boundaryGateEnded(_:)))
                    gate.isEnabled = isVisible && transition == nil && currentID != nil && currentID == ids.last
                    gate.delegate = self
                    gate.maximumNumberOfTouches = 1
                    gate.cancelsTouchesInView = false
                    gate.delaysTouchesBegan = false
                    gate.delaysTouchesEnded = false
                    scroll.addGestureRecognizer(gate)
                    scroll.panGestureRecognizer.require(toFail: gate)
                    boundaryGate = gate
                }
            }
            let gateEnabled = isVisible && transition == nil && currentID != nil && currentID == ids.last
            if let boundaryGate, boundaryGate.isEnabled != gateEnabled { boundaryGate.isEnabled = gateEnabled }
            scroll.contentInsetAdjustmentBehavior = .never
            scroll.contentInset = .zero
            scroll.scrollIndicatorInsets = .zero
            scroll.showsVerticalScrollIndicator = false
            scroll.showsHorizontalScrollIndicator = false
            // This offset belongs to UIPageViewController's internal page queue;
            // system scroll-to-top must not compete with explicit focus requests.
            scroll.scrollsToTop = false
            scroll.accessibilityIdentifier = isVisible ? activeAccessibilityIdentifier : "inactive." + activeAccessibilityIdentifier
            #if DEBUG && targetEnvironment(simulator)
            if PagerGestureTraceQA.enabled, let container {
                if touchTrace == nil {
                    let trace = PagerGestureTraceQA()
                    trace.nativeState = { [weak self] in
                        guard let self else { return [:] }
                        var value: [String: Any] = ["instance": self.debugInstanceID,
                            "currentID": self.currentID as Any? ?? NSNull(),
                            "focused": self.configuration.focused as Any? ?? NSNull(),
                            "displayedIDs": (self.controller?.viewControllers ?? []).compactMap { ($0 as? NativePageHost)?.id },
                            "ids": self.ids, "nativeQueueRevision": self.nativeQueueRevision,
                            "queueRevision": self.configuration.queueRevision,
                            "focusRequest": self.configuration.focusRequest,
                            "transitionActive": self.transition != nil,
                            "pendingFocused": self.pending?.focused as Any? ?? NSNull(),
                            "latestBoundaryWaiting": (self.pending ?? self.configuration).boundaryWaiting,
                            "boundaryGateActive": self.boundaryGate?.state == .began || self.boundaryGate?.state == .changed]
                        if let view = self.controller?.viewControllers?.first?.viewIfLoaded, let container = self.container {
                            let rect = view.convert(view.bounds, to: container.view)
                            value["displayedRelativeFrame"] = ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]
                        }
                        return value
                    }
                    touchTrace = trace
                }
                touchTrace?.attach(viewport: container.view, scroll: scroll, visible: isVisible)
            }
            #endif
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard recognizer === boundaryGate, let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return isVisible && transition == nil && currentID != nil && currentID == ids.last &&
                (velocity.y < 0 || (configuration.boundaryWaiting && velocity.y > 0)) &&
                abs(velocity.y) > abs(velocity.x)
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard recognizer === boundaryGate, isVisible, transition == nil,
                  currentID != nil, currentID == ids.last else { return false }
            var target = touch.view
            while let view = target {
                if view is UIControl { return false }
                target = view.superview
            }
            return true
        }

        @objc private func boundaryGateEnded(_ pan: UIPanGestureRecognizer) {
            #if DEBUG && targetEnvironment(simulator)
            touchTrace?.record("native.boundaryGate", ["state": pan.state.rawValue],
                sampleKey: pan.state == .changed ? "native.boundaryGate.changed" : nil)
            #endif
            guard pan === boundaryGate, pan.state == .ended else { return }
            requestBoundaryContinuation(pan)
        }

        /// A real upward swipe at the last page is demand, even when there is no
        /// neighbor to settle on. Never infer demand from layout or programmatic focus.
        @objc private func boundaryPanEnded(_ pan: UIPanGestureRecognizer) {
            #if DEBUG && targetEnvironment(simulator)
            touchTrace?.pan(pan)
            #endif
            guard pan.state == .ended else { return }
            requestBoundaryContinuation(pan)
        }

        private func requestBoundaryContinuation(_ pan: UIPanGestureRecognizer) {
            guard isVisible, transition == nil,
                  let currentID, currentID == ids.last else { return }
            let delta = pan.translation(in: pan.view)
            if configuration.boundaryWaiting, delta.y > 36, abs(delta.y) > abs(delta.x) * 1.2 {
                configuration.onUserBoundaryCancel?()
                return
            }
            guard delta.y < -36, abs(delta.y) > abs(delta.x) * 1.2 else { return }
            configuration.onUserBoundaryDemand?(currentID)
            configuration.onUserContinuationDemand?(currentID)
        }

        func layoutChanged() {
            configureScrollView()
            #if DEBUG && targetEnvironment(simulator)
            configuration.frames.focusedID = currentID
            if let container { configuration.frames.viewport = container.view }
            configuration.frames.refresh()
            debugSnapshot(event: "layout")
            #endif
        }

        #if DEBUG && targetEnvironment(simulator)
        /// Only the opt-in, synthetic resume QA route writes these native snapshots.
        /// Coalesce to 20 Hz and compare state without timestamp/event metadata.
        private func debugSnapshot(event: String) {
            guard ResumePromptQA.enabled || ProcessInfo.processInfo.arguments.contains("--qa-native-layout64") else { return }
            debugLastEvent = event
            guard debugSnapshotWork == nil else { return }
            let delay = max(0, 0.05 - (CACurrentMediaTime() - debugLastWrite))
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.debugSnapshotWork = nil
                self.writeDebugSnapshot()
            }
            debugSnapshotWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        private func debugNavigationOperation(_ operation: String, target: Int) {
            guard ResumePromptQA.enabled || ProcessInfo.processInfo.arguments.contains("--qa-native-layout64") else { return }
            let scroll = controller?.viewIfLoaded?.subviews.compactMap { $0 as? UIScrollView }.first
            let displayed = controller?.viewControllers?.first as? NativePageHost
            let record: [String: Any] = [
                "operation": operation,
                "uptime": CACurrentMediaTime(),
                "target": target,
                "nativeQueueRevision": nativeQueueRevision,
                "displayedID": displayed?.id as Any? ?? NSNull(),
                "displayedView": debugView(displayed?.viewIfLoaded),
                "offsetY": scroll.map { Double($0.contentOffset.y) } as Any? ?? NSNull(),
                "contentHeight": scroll.map { Double($0.contentSize.height) } as Any? ?? NSNull(),
                "dataSourceAttached": controller?.dataSource != nil
            ]
            debugNavigationOperations.append(record)
            if debugNavigationOperations.count > 12 { debugNavigationOperations.removeFirst(debugNavigationOperations.count - 12) }
            debugSnapshot(event: operation)
        }

        private func debugRect(_ rect: CGRect) -> [String: Double] {
            ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]
        }
        private func debugInsets(_ insets: UIEdgeInsets) -> [String: Double] {
            ["top": Double(insets.top), "left": Double(insets.left), "bottom": Double(insets.bottom), "right": Double(insets.right)]
        }
        private func debugView(_ view: UIView?) -> Any {
            guard let view else { return NSNull() }
            return [
                "bounds": debugRect(view.bounds),
                "frame": debugRect(view.frame),
                "windowFrame": view.window.map { debugRect(view.convert(view.bounds, to: $0)) } as Any? ?? NSNull(),
                "hasWindow": view.window != nil,
                "isHidden": view.isHidden,
                "alpha": Double(view.alpha),
                "layerOpacity": Double(view.layer.opacity),
                "isUserInteractionEnabled": view.isUserInteractionEnabled,
                "accessibilityElementsHidden": view.accessibilityElementsHidden,
                "safeAreaInsets": debugInsets(view.safeAreaInsets),
                "clipsToBounds": view.clipsToBounds
            ] as [String: Any]
        }
        private func writeDebugSnapshot() {
            guard ResumePromptQA.enabled || ProcessInfo.processInfo.arguments.contains("--qa-native-layout64") else { return }
            let nativeView = controller?.viewIfLoaded
            let scroll = nativeView?.subviews.compactMap { $0 as? UIScrollView }.first
            var ancestors: [Any] = []
            var ancestor = nativeView?.superview
            for _ in 0..<5 {
                guard let view = ancestor else { break }
                ancestors.append(debugView(view)); ancestor = view.superview
            }
            let displayed: [[String: Any]] = (controller?.viewControllers ?? []).map { page in
                ["id": (page as? NativePageHost)?.id as Any? ?? NSNull(),
                 "view": debugView(page.viewIfLoaded), "hasParent": page.parent != nil]
            }
            var state: [String: Any] = [
                "currentID": currentID as Any? ?? NSNull(),
                "focused": configuration.focused as Any? ?? NSNull(),
                "configurationViewport": ["width": Double(configuration.viewport.width), "height": Double(configuration.viewport.height)],
                "configurationVisible": configuration.isVisible,
                "latestVisibility": isVisible,
                "hasPendingConfiguration": pending != nil,
                "pendingVisible": pending.map(\.isVisible) as Any? ?? NSNull(),
                "pendingFocused": pending?.focused as Any? ?? NSNull(),
                "transitionActive": transition != nil,
                "transitionStartFocused": transition?.focused as Any? ?? NSNull(),
                "queueCount": ids.count,
                "queueRevision": configuration.queueRevision,
                "focusRequest": configuration.focusRequest,
                "controllerHasParent": controller?.parent != nil,
                "controllerView": debugView(nativeView),
                "containerView": debugView(container?.viewIfLoaded),
                "nativeQueueRevision": nativeQueueRevision,
                "displayedControllers": displayed,
                "ancestorViews": ancestors,
                "cachedIDs": hosts.keys.map(\.id).sorted(),
                "pageDataSourceAttached": controller?.dataSource != nil,
                "navigationOperations": debugNavigationOperations
            ]
            if let scroll {
                state["scroll"] = [
                    "view": debugView(scroll),
                    "contentOffset": ["x": Double(scroll.contentOffset.x), "y": Double(scroll.contentOffset.y)],
                    "contentSize": ["width": Double(scroll.contentSize.width), "height": Double(scroll.contentSize.height)],
                    "contentInset": debugInsets(scroll.contentInset),
                    "adjustedContentInset": debugInsets(scroll.adjustedContentInset),
                    "scrollsToTop": scroll.scrollsToTop,
                    "isScrollEnabled": scroll.isScrollEnabled,
                    "isPagingEnabled": scroll.isPagingEnabled,
                    "isDragging": scroll.isDragging,
                    "isDecelerating": scroll.isDecelerating,
                    "panState": scroll.panGestureRecognizer.state.rawValue,
                    "identifier": scroll.accessibilityIdentifier as Any? ?? NSNull()
                ] as [String: Any]
            } else { state["scroll"] = NSNull() }
            guard let comparable = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
                  comparable != debugLastState else { return }
            let snapshot: [String: Any] = [
                "instanceID": debugInstanceID,
                "event": debugLastEvent,
                "timestamp": Date().timeIntervalSince1970,
                "state": state
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) else { return }
            debugLastWrite = CACurrentMediaTime()
            do {
                try FileManager.default.createDirectory(at: ResumePromptQA.rootURL, withIntermediateDirectories: true)
                try data.write(to: ResumePromptQA.rootURL.appendingPathComponent("native-state-\(debugInstanceID)-instance.json"), options: .atomic)
                debugLastState = comparable
            } catch { /* QA telemetry never changes production paging behavior. */ }
        }
        #endif

        func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard pageViewController === controller else { return nil }
            return neighbor(of: viewController, offset: -1)
        }
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard pageViewController === controller else { return nil }
            return neighbor(of: viewController, offset: 1)
        }
        private func neighbor(of viewController: UIViewController, offset: Int) -> UIViewController? {
            guard let page = viewController as? NativePageHost, let index = ids.firstIndex(of: page.id), ids.indices.contains(index + offset) else { return nil }
            return host(for: ids[index + offset])
        }
        func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
            guard pageViewController === controller else { return }
            #if DEBUG && targetEnvironment(simulator)
            touchTrace?.record("native.willTransition", ["pendingIDs": pendingViewControllers.compactMap { ($0 as? NativePageHost)?.id }])
            #endif
            transition = Transition(focused: configuration.focused, request: configuration.focusRequest, revision: configuration.queueRevision)
            #if DEBUG && targetEnvironment(simulator)
            debugSnapshot(event: "willTransition")
            #endif
        }
        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard pageViewController === controller, let started = transition else { return }
            #if DEBUG && targetEnvironment(simulator)
            touchTrace?.record("native.didFinish", ["finished": finished, "completed": completed,
                "previousIDs": previousViewControllers.compactMap { ($0 as? NativePageHost)?.id },
                "displayedIDs": (pageViewController.viewControllers ?? []).compactMap { ($0 as? NativePageHost)?.id }])
            #endif
            // UIPageViewController restores its original controller on cancellation.
            // Only its settled, displayed controller is allowed to change focus.
            let displayedID = (pageViewController.viewControllers?.first as? NativePageHost)?.id
            let settled = (completed ? displayedID : (previousViewControllers.first as? NativePageHost)?.id) ?? currentID
            currentID = settled
            transition = nil
            cancelPendingApply()
            let latest = pending ?? configuration
            pending = nil
            let redirected = latest.focused != started.focused || latest.focusRequest != started.request || latest.queueRevision != started.revision
            if !redirected, let settled, latest.ids.contains(settled) {
                latest.focused = settled
                // This delegate represents an interactive transition. Publish intent
                // only after a completed gesture has established the actual focus.
                if completed, let displayedID, displayedID == settled {
                    latest.onUserPageSettled?(displayedID)
                    if let previous = started.focused.flatMap({ latest.ids.firstIndex(of: $0) }),
                       let next = latest.ids.firstIndex(of: displayedID), next > previous,
                       next >= latest.ids.count - 4 {
                        latest.onUserContinuationDemand?(displayedID)
                    }
                }
            }
            if nativeScrollIsMoving {
                pending = latest
                refreshHosts(using: latest)
                schedulePendingApply()
            } else {
                apply(latest, settledID: redirected ? nil : settled)
            }
            #if DEBUG && targetEnvironment(simulator)
            touchTrace?.record("native.didSettle", ["redirected": redirected, "settled": settled as Any? ?? NSNull()])
            #endif
            #if DEBUG && targetEnvironment(simulator)
            debugSnapshot(event: "didFinish.completed=\(completed).finished=\(finished).redirected=\(redirected)")
            #endif
        }
    }
}

/// SwiftUI owns this stable controller. Its replaceable child owns all native
/// paging internals; media hosts remain in the coordinator's bounded cache.
private final class NativePagerContainerController: UIViewController {
    private(set) var pageController: NativePageController?
    var onLayout: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.clipsToBounds = true
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let child = pageController, child.view.frame != view.bounds { child.view.frame = view.bounds }
        onLayout?()
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); onLayout?() }

    func installPageController(_ next: NativePageController) {
        precondition(pageController == nil)
        let visible = view.window != nil
        addChild(next)
        next.view.frame = view.bounds
        next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if visible { next.beginAppearanceTransition(true, animated: false) }
        view.addSubview(next.view)
        next.didMove(toParent: self)
        pageController = next
        if visible { next.endAppearanceTransition() }
    }

    func removePageController(preservingHosts: [NativePageHost]) {
        guard let previous = pageController else { return }
        previous.onLayout = nil
        previous.delegate = nil
        previous.dataSource = nil
        let visible = previous.viewIfLoaded?.window != nil
        // Finish appearance forwarding while the old child hierarchy is intact,
        // so retained SwiftUI hosts receive balanced disappearance callbacks.
        if visible { previous.beginAppearanceTransition(false, animated: false) }
        previous.willMove(toParent: nil)
        previous.viewIfLoaded?.removeFromSuperview()
        if visible { previous.endAppearanceTransition() }

        var retained: [ObjectIdentifier: NativePageHost] = [:]
        func collect(_ child: UIViewController) {
            if let host = child as? NativePageHost { retained[ObjectIdentifier(host)] = host }
            else { child.children.forEach(collect) }
        }
        previous.children.forEach(collect)
        for host in preservingHosts { retained[ObjectIdentifier(host)] = host }
        for host in retained.values {
            let hasParent = host.parent != nil
            if hasParent { host.willMove(toParent: nil) }
            host.viewIfLoaded?.removeFromSuperview()
            if hasParent { host.removeFromParent() }
        }
        previous.removeFromParent()
        pageController = nil
    }
}

private final class NativePageController: UIPageViewController {
    var onLayout: (() -> Void)?
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); onLayout?() }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); onLayout?() }
}

private final class NativePageHost: UIHostingController<AnyView> {
    let id: Int
    init(id: Int, rootView: AnyView) { self.id = id; super.init(rootView: rootView) }
    @MainActor required dynamic init?(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

#if DEBUG && targetEnvironment(simulator)
/// Preferences stop at a hosting boundary. Preserve the existing QA source keys,
/// translating from that root's coordinates through its actual UIView to the window.
@MainActor private final class NativePagerFrameBridge: ObservableObject {
    @Published private(set) var collection: [String: CGRect] = [:]
    @Published private(set) var resume: [String: CGRect] = [:]
    @Published private(set) var playback: [String: CGRect] = [:]
    weak var viewport: UIView?
    var focusedID: Int?
    var isVisible = true {
        didSet { if oldValue != isVisible { refresh() } }
    }
    private var hosts: [Int: WeakHost] = [:]
    private var values: [Int: [String: [String: CGRect]]] = [:]
    private var scheduled = false
    private struct WeakHost { weak var value: UIViewController? }
    func register(_ host: UIViewController, id: Int) { hosts[id] = WeakHost(value: host) }
    func retain(ids: Set<Int>) { hosts = hosts.filter { ids.contains($0.key) }; values = values.filter { ids.contains($0.key) }; refresh() }
    func receive(_ frames: [String: CGRect], kind: String, id: Int) { values[id, default: [:]][kind] = frames; refresh() }
    func clear() { hosts.removeAll(); values.removeAll(); viewport = nil; refresh() }
    func refresh() {
        guard !scheduled else { return }; scheduled = true
        DispatchQueue.main.async { [weak self] in self?.publish() }
    }
    private func publish() {
        scheduled = false
        guard isVisible else {
            if !collection.isEmpty { collection = [:] }
            if !resume.isEmpty { resume = [:] }
            if !playback.isEmpty { playback = [:] }
            return
        }
        var output: [String: [String: CGRect]] = [:]
        for (id, kinds) in values {
            guard let view = hosts[id]?.value?.viewIfLoaded, let window = view.window else { continue }
            for (kind, frames) in kinds {
                if kind == "playback", id != focusedID { continue }
                guard let root = frames["__nativeRoot"] else { continue }
                for (key, frame) in frames where key != "__nativeRoot" {
                    output[kind, default: [:]][key] = view.convert(frame.offsetBy(dx: -root.minX, dy: -root.minY), to: window)
                }
            }
        }
        if let viewport, let window = viewport.window {
            let frame = viewport.convert(viewport.bounds, to: window)
            if CollectionPagingQA.enabled { output["collection", default: [:]]["viewport"] = frame }
            if ResumePromptQA.enabled { output["resume", default: [:]]["viewport"] = frame }
        }
        let nextCollection = output["collection"] ?? [:]
        let nextResume = output["resume"] ?? [:]
        let nextPlayback = output["playback"] ?? [:]
        if collection != nextCollection { collection = nextCollection }
        if resume != nextResume { resume = nextResume }
        if playback != nextPlayback { playback = nextPlayback }
    }
}

private struct NativePagerQAContent: View {
    let content: AnyView
    let id: Int
    let bridge: NativePagerFrameBridge
    var body: some View {
        content.background(GeometryReader { geometry in
            Color.clear
                .preference(key: CollectionPagingQAFrameKey.self, value: ["__nativeRoot": geometry.frame(in: .global)])
                .preference(key: ResumePromptQAFrameKey.self, value: ["__nativeRoot": geometry.frame(in: .global)])
                .preference(key: PlaybackLayoutQAFrameKey.self, value: ["__nativeRoot": geometry.frame(in: .global)])
        })
        .onPreferenceChange(CollectionPagingQAFrameKey.self) { bridge.receive($0, kind: "collection", id: id) }
        .onPreferenceChange(ResumePromptQAFrameKey.self) { bridge.receive($0, kind: "resume", id: id) }
        .onPreferenceChange(PlaybackLayoutQAFrameKey.self) { bridge.receive($0, kind: "playback", id: id) }
    }
}
#endif
