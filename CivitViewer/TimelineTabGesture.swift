import SwiftUI
import UIKit

private struct CompactBarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The production and UI-test roots use the same tab ownership, navigation
/// containers, labels and observation point. Content dependencies stay outside.
struct MainTabs<Timeline: View, Authors: View, Search: View, Settings: View>: View {
    @Binding var selectedTab: Int
    var onTimelineTap: () -> Void
    var onTimelineDoubleTap: () -> Void
    let timeline: Timeline
    let authors: Authors
    let search: Search
    let settings: Settings
    @ObservedObject private var chrome = ViewingChromeController.shared
    @State private var previousTimelineTap: CFTimeInterval?
    @State private var lastTimelineRefresh = -Double.infinity
    @State private var compactBarHeight: CGFloat = 48
    private let destinations: [(Int, String, String)] = [
        (0, "时间线", "rectangle.portrait.on.rectangle.portrait"),
        (2, "作者榜", "person.3"), (4, "搜索", "magnifyingglass"), (3, "我", "person.crop.circle")
    ]

    var body: some View {
        VStack(spacing: 0) {
        TabView(selection: $selectedTab) {
            NavigationStack { timeline }
                .toolbar(.hidden, for: .tabBar)
                .tabItem { Label("时间线", systemImage: "rectangle.portrait.on.rectangle.portrait").accessibilityIdentifier("main.tab.timeline") }.tag(0)
            NavigationStack { authors }
                .toolbar(.hidden, for: .tabBar)
                .tabItem { Label("作者榜", systemImage: "person.3") }.tag(2)
            NavigationStack { search }
                .toolbar(.hidden, for: .tabBar)
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }.tag(4)
            NavigationStack { settings }
                .toolbar(.hidden, for: .tabBar)
                .tabItem { Label("我", systemImage: "person.crop.circle") }.tag(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.viewingBottomBarHeight, chrome.hasViewer ? compactBarHeight : 0)
        if !chrome.hasViewer { measuredBar }
        }
        .overlay(alignment: .bottom) {
            if chrome.hasViewer { measuredBar.viewingChromeHidden(chrome.hidden) }
        }
        .onPreferenceChange(CompactBarHeightKey.self) { if $0 > 0 { compactBarHeight = $0 } }
        .tint(.blue)
        .onChange(of: selectedTab) { _, _ in chrome.reveal() }
    }

    private var measuredBar: some View {
        compactBar.background(GeometryReader { geometry in
            Color.clear.preference(key: CompactBarHeightKey.self, value: geometry.size.height)
        })
    }

    private var compactBar: some View {
        HStack(spacing: 0) {
            ForEach(destinations, id: \.0) { destination in
                if destination.0 == 0 {
                    tabButton(destination).accessibilityAction(named: Text("从头刷新时间线")) { refreshTimeline() }
                } else { tabButton(destination) }
            }
        }.padding(.horizontal, 8).padding(.vertical, 2)
            .background {
                if chrome.hasViewer {
                    RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.35))
                } else {
                    RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(chrome.hasViewer ? Color.white.opacity(0.12) : Color.primary.opacity(0.06), lineWidth: 0.5))
            .padding(.horizontal, 12)
            .accessibilityElement(children: .contain).accessibilityAddTraits(.isTabBar)
            .accessibilityIdentifier("main.tabs.compact")
    }
    private func tabButton(_ destination: (Int, String, String)) -> some View {
        Button { select(destination.0) } label: {
                    VStack(spacing: 3) {
                        Image(systemName: destination.2).font(.system(size: 19, weight: .medium)).frame(height: 20)
                        Text(destination.1).font(.caption2.weight(selectedTab == destination.0 ? .semibold : .regular))
                            .lineLimit(1).minimumScaleFactor(0.65).padding(.horizontal, 4)
                    }.frame(minWidth: 0, maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(selectedTab == destination.0 ? Color.accentColor : (chrome.hasViewer ? Color.white.opacity(0.88) : Color.secondary))
                        .shadow(color: .black.opacity(chrome.hasViewer ? 0.7 : 0), radius: 2, y: 1)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).frame(minWidth: 0, maxWidth: .infinity).accessibilityLabel(destination.1)
                    .accessibilityIdentifier(destination.0 == 0 ? "main.tab.timeline" : "main.tab.\(destination.0)")
                    .accessibilityAddTraits(selectedTab == destination.0 ? .isSelected : [])
    }
    private func select(_ id: Int) {
        selectedTab = id
        guard id == 0 else { previousTimelineTap = nil; return }
        let now = CACurrentMediaTime()
        if let previousTimelineTap, now - previousTimelineTap <= 0.4 {
            self.previousTimelineTap = nil; refreshTimeline()
        } else {
            previousTimelineTap = now; onTimelineTap()
        }
    }
    private func refreshTimeline() {
        let now = CACurrentMediaTime()
        guard now - lastTimelineRefresh >= 0.65 else { return }
        lastTimelineRefresh = now; onTimelineDoubleTap()
    }
}

/// Observe completed taps without replacing SwiftUI's tab delegate. A single
/// completed tap returns to the current queue's start. A second nearby tap
/// requests a new first page; it is not left to UIKit's re-selection behavior.
struct TimelineTabDoubleTap: UIViewRepresentable {
    var onTap: () -> Void
    var onDoubleTap: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap, onDoubleTap: onDoubleTap) }
    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        view.onLayout = { [weak coordinator = context.coordinator] in coordinator?.attach() }
        context.coordinator.probe = view
        return view
    }
    func updateUIView(_ view: Probe, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onDoubleTap = onDoubleTap
        context.coordinator.attach()
    }
    static func dismantleUIView(_ view: Probe, coordinator: Coordinator) { coordinator.detach() }
    final class Probe: UIView {
        var onLayout: (() -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); onLayout?() }
        override func layoutSubviews() { super.layoutSubviews(); onLayout?() }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var probe: Probe?
        private weak var host: UIWindow?
        private weak var bar: UITabBar?
        private weak var item: UITabBarItem?
        var onTap: () -> Void
        var onDoubleTap: () -> Void
        private var retry: DispatchWorkItem?
        private var attempts = 0
        private var previousTap: (time: CFTimeInterval, point: CGPoint)?
        private var lastDelivery = -Double.infinity
        private var customAction: UIAccessibilityCustomAction?
        private lazy var gesture: UITapGestureRecognizer = {
            let value = UITapGestureRecognizer(target: self, action: #selector(tapped))
            value.cancelsTouchesInView = false
            value.delaysTouchesBegan = false
            value.delaysTouchesEnded = false
            value.delegate = self
            return value
        }()
        init(onTap: @escaping () -> Void, onDoubleTap: @escaping () -> Void) {
            self.onTap = onTap; self.onDoubleTap = onDoubleTap
        }
        func attach() {
            guard let window = probe?.window else { detach(); return }
            var candidates: [UITabBarController] = []
            func collect(_ controller: UIViewController?) {
                guard let controller else { return }
                if let tabs = controller as? UITabBarController,
                   tabs.tabBar.window === window, tabs.tabBar.items?.first?.title == "时间线" {
                    candidates.append(tabs)
                }
                for child in controller.children { collect(child) }
                collect(controller.presentedViewController)
            }
            // Prefer the Probe's own controller ancestry. The zero-size
            // TabView background may instead be hosted above the tab controller;
            // in that case accept only one matching controller in this window.
            var responder: UIResponder? = probe
            var owner: UITabBarController?
            while let value = responder {
                if let controller = value as? UIViewController,
                   let tabs = (controller as? UITabBarController) ?? controller.tabBarController,
                   tabs.tabBar.items?.first?.title == "时间线" { owner = tabs; break }
                responder = value.next
            }
            if owner == nil {
                collect(window.rootViewController)
                if candidates.count == 1 { owner = candidates[0] }
            }
            guard let target = owner?.tabBar, let first = target.items?.first else {
                guard attempts < 12, retry == nil else { return }
                attempts += 1
                let work = DispatchWorkItem { [weak self] in self?.retry = nil; self?.attach() }
                retry = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
                return
            }
            retry?.cancel(); retry = nil; attempts = 0
            if host !== window {
                host?.removeGestureRecognizer(gesture)
                host = window; previousTap = nil
                window.addGestureRecognizer(gesture)
            }
            bar = target
            if item !== first {
                removeCustomAction()
                item = first
                first.accessibilityIdentifier = "main.tab.timeline"
                let action = UIAccessibilityCustomAction(name: "从头刷新时间线", target: self, selector: #selector(accessibleRestart))
                customAction = action
                first.accessibilityCustomActions = (first.accessibilityCustomActions ?? []) + [action]
            }
        }
        private func removeCustomAction() {
            if let action = customAction { item?.accessibilityCustomActions?.removeAll { $0 === action } }
            item = nil; customAction = nil
        }
        func detach() {
            retry?.cancel(); retry = nil; attempts = 0
            host?.removeGestureRecognizer(gesture); host = nil; bar = nil; previousTap = nil
            removeCustomAction()
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let bar, let host, bar.window === host, !bar.isHidden,
                  let title = item?.title, let touched = touch.view,
                  touched === bar || touched.isDescendant(of: bar) else { previousTap = nil; return false }
            let point = touch.location(in: bar)
            guard bar.bounds.contains(point) else { previousTap = nil; return false }
            func matches(_ view: UIView) -> Bool {
                view.accessibilityIdentifier == "main.tab.timeline" || view.accessibilityLabel == title || (view as? UILabel)?.text == title
            }
            var ancestor: UIView? = touched
            while let view = ancestor, view !== bar {
                if matches(view) { return true }
                ancestor = view.superview
            }
            // Resolve the actual labelled control instead of assuming that the
            // number of UIKit implementation controls equals the number of tabs.
            func containsLabel(_ view: UIView) -> Bool {
                matches(view) || view.subviews.contains(where: containsLabel)
            }
            func matchingControl(_ view: UIView) -> Bool {
                for child in view.subviews where !child.isHidden && child.alpha > 0.01 {
                    if child is UIControl, containsLabel(child), child.convert(child.bounds, to: bar).contains(point) { return true }
                    if matchingControl(child) { return true }
                }
                return false
            }
            let accepted = matchingControl(bar)
            if !accepted { previousTap = nil }
            return accepted
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
        private func deliver() {
            let now = CACurrentMediaTime()
            guard now - lastDelivery >= 0.65 else { return }
            lastDelivery = now; onDoubleTap()
        }
        @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let host else { return }
            let now = CACurrentMediaTime(), point = recognizer.location(in: host)
            if let previousTap, now - previousTap.time <= 0.4,
               hypot(point.x - previousTap.point.x, point.y - previousTap.point.y) <= 30 {
                self.previousTap = nil
                deliver()
            } else {
                previousTap = (now, point)
                onTap()
            }
        }
        @objc private func accessibleRestart(_ action: UIAccessibilityCustomAction) -> Bool {
            previousTap = nil; deliver(); return true
        }
    }
}
