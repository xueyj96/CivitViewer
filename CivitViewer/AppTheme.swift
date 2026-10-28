import SwiftUI
import UIKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色" }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

enum AppTheme {
    static let appearanceKey = "app.appearance"
    static let spacing: CGFloat = 16
    static let secondarySurface = Color(uiColor: .secondarySystemBackground)
}

/// Small, flat controls share a 44-point hit area across sheets and lists.
/// The fill stays quieter than the selected state or primary content.
struct AppActionButtonStyle: ButtonStyle {
    enum Tone { case neutral, accent, destructive }
    var tone: Tone = .neutral
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appToolbarSingleLine) private var singleLine

    private var ink: Color {
        switch tone { case .neutral: .primary; case .accent: .blue; case .destructive: .red }
    }
    private var fill: Color {
        switch tone {
        case .neutral: scheme == .dark ? .white.opacity(0.09) : .black.opacity(0.05)
        case .accent: .blue.opacity(scheme == .dark ? 0.20 : 0.10)
        case .destructive: .red.opacity(scheme == .dark ? 0.18 : 0.09)
        }
    }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(singleLine ? 1 : nil)
            .fixedSize(horizontal: singleLine, vertical: false)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(ink)
            .padding(.horizontal, 8)
            .frame(minHeight: 32)
            .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.38)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A filter can be scanned before opening the menu; the chevron is deliberate.
struct AppFilterLabel: View {
    let title: String
    let symbol: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        }
    }
}

/// iOS 26 adds a shared glass container to toolbar items. These controls already
/// draw their own flat fill, so keep a single background on newer systems.
struct AppToolbarItem<Content: View>: ToolbarContent {
    var placement: ToolbarItemPlacement = .automatic
    @ViewBuilder let content: () -> Content
    var body: some ToolbarContent {
        if #available(iOS 26, *) {
            ToolbarItem(placement: placement) { content().buttonStyle(AppActionButtonStyle()).environment(\.appToolbarSingleLine, true) }.sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: placement) { content().buttonStyle(AppActionButtonStyle()).environment(\.appToolbarSingleLine, true) }
        }
    }
}

private struct AppToolbarSingleLineKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    fileprivate var appToolbarSingleLine: Bool {
        get { self[AppToolbarSingleLineKey.self] }
        set { self[AppToolbarSingleLineKey.self] = newValue }
    }
}

private struct OrdinaryColorSchemeKey: EnvironmentKey {
    static let defaultValue: ColorScheme = .light
}

extension EnvironmentValues {
    /// Kept separately from the local media canvas, which is always dark.
    var ordinaryColorScheme: ColorScheme {
        get { self[OrdinaryColorSchemeKey.self] }
        set { self[OrdinaryColorSchemeKey.self] = newValue }
    }
}

private struct AppRootAppearance: ViewModifier {
    @Environment(\.colorScheme) private var systemScheme
    @AppStorage(AppTheme.appearanceKey) private var preference = AppAppearance.system.rawValue
    private var selection: AppAppearance { AppAppearance(rawValue: preference) ?? .system }
    func body(content: Content) -> some View {
        content
            .environment(\.ordinaryColorScheme, selection.colorScheme ?? systemScheme)
            .preferredColorScheme(selection.colorScheme)
            .tint(.blue)
            #if DEBUG && targetEnvironment(simulator)
            .overlay(alignment: .topTrailing) {
                if CollectionPagingQA.enabled && ProcessInfo.processInfo.arguments.contains("--qa-style49") { NativeBack49Readback() }
            }
            .overlay(alignment: .topLeading) {
                if ProcessInfo.processInfo.arguments.contains("--qa-theme-ui") && CollectionPagingQA.enabled {
                    let value = "theme=\((selection.colorScheme ?? systemScheme) == .dark ? "dark" : "light");preference=\(preference)"
                    Text(value).font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                        .accessibilityElement(children: .ignore).accessibilityIdentifier("qa.theme.state").accessibilityValue(value)
                }
            }
            #endif
    }
}

private struct OrdinaryAppearance: ViewModifier {
    @Environment(\.ordinaryColorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .tint(.blue)
            .background(Color(uiColor: .systemBackground))
            .environment(\.colorScheme, scheme)
            .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(scheme, for: .navigationBar)
    }
}

/// Native back items ignore the shared-background opt-out on current iOS.
/// Use the same explicit flat control as other actions, with SwiftUI owning
/// dismissal and UIKit retaining the interactive transition.
private struct FlatNavigationBack: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    @State private var canGoBack = false
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .navigationBarBackButtonHidden(true)
                .toolbar {
                    if canGoBack {
                        AppToolbarItem(placement: .topBarLeading) {
                            Button(action: { dismiss() }) {
                                Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                            }
                            .accessibilityLabel("返回")
                            .accessibilityIdentifier("navigation.back")
                        }
                    }
                }
                .background {
                    FlatBackNavigationSupport(canGoBack: $canGoBack)
                        .frame(width: 1, height: 1).allowsHitTesting(false).accessibilityHidden(true)
                }
        } else { content }
    }
}

private struct FlatBackNavigationSupport: UIViewControllerRepresentable {
    @Binding var canGoBack: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> Probe {
        let controller = Probe()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        let coordinator = context.coordinator
        coordinator.setCanGoBack = { canGoBack = $0 }
        controller.onAttach = { [weak controller, weak coordinator] in
            guard let controller else { return }; coordinator?.apply(from: controller)
        }
        return controller
    }

    func updateUIViewController(_ controller: Probe, context: Context) {
        let coordinator = context.coordinator
        coordinator.setCanGoBack = { canGoBack = $0 }
        DispatchQueue.main.async { [weak controller] in
            guard let controller else { return }
            coordinator.apply(from: controller)
        }
    }

    static func dismantleUIViewController(_ controller: Probe, coordinator: Coordinator) {
        controller.onAttach = nil
        coordinator.restoreGesture()
    }

    final class Probe: UIViewController {
        var onAttach: (() -> Void)?
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            DispatchQueue.main.async { [weak self] in self?.onAttach?() }
        }
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            DispatchQueue.main.async { [weak self] in self?.onAttach?() }
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onAttach?()
        }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var setCanGoBack: ((Bool) -> Void)?
        private weak var navigationController: UINavigationController?
        private weak var owner: UIViewController?
        private final class PopBinding {
            weak var gesture: UIGestureRecognizer?
            var delegate: UIGestureRecognizerDelegate?
            let enabled: Bool
            init(_ gesture: UIGestureRecognizer, delegate: UIGestureRecognizerDelegate?, enabled: Bool) {
                self.gesture = gesture; self.delegate = delegate; self.enabled = enabled
            }
        }
        private var bindings: [PopBinding] = []

        func apply(from controller: UIViewController) {
            guard #available(iOS 26.0, *) else { return }
            var ancestor: UIViewController? = controller
            var host: UIViewController?
            var navigation: UINavigationController?
            while let current = ancestor {
                if let found = current.navigationController,
                   found.viewControllers.contains(where: { $0 === current }) {
                    host = current
                    navigation = found
                    break
                }
                ancestor = current.parent
            }
            guard let host, let navigation, navigation.topViewController === host else {
                return
            }
            let hasPrevious = navigation.viewControllers.count > 1
            setCanGoBack?(hasPrevious)
            if let transition = navigation.transitionCoordinator {
                transition.animate(alongsideTransition: nil) { [weak self, weak controller] _ in
                    guard let controller else { return }; self?.apply(from: controller)
                }
                return
            }
            if hasPrevious {
                if navigationController !== navigation { restoreGesture() }
                self.navigationController = navigation
                owner = host
                // iOS 26 also routes return pans through the content recognizer.
                // Keep both UIKit recognizers/actions; constrain the content
                // recognizer to the same leading edge as the classic gesture.
                for gesture in [navigation.interactivePopGestureRecognizer, navigation.interactiveContentPopGestureRecognizer].compactMap({ $0 }) {
                    if gesture.delegate !== self {
                        bindings.removeAll { $0.gesture === gesture }
                        let prior = (gesture.delegate as? Coordinator)?.bindings.first { $0.gesture === gesture }
                        let original = prior != nil ? prior?.delegate : gesture.delegate
                        bindings.append(PopBinding(gesture, delegate: original, enabled: prior?.enabled ?? gesture.isEnabled))
                        gesture.delegate = self
                    }
                    gesture.isEnabled = true
                }
            } else { restoreGesture() }
            recordQA(navigation)
        }

        func restoreGesture() {
            for binding in bindings {
                if let gesture = binding.gesture, gesture.delegate === self {
                    gesture.delegate = binding.delegate
                    gesture.isEnabled = binding.enabled
                }
            }
            bindings.removeAll()
            navigationController = nil
            owner = nil
        }

        private func eligible(_ gesture: UIGestureRecognizer) -> Bool {
            guard bindings.contains(where: { $0.gesture === gesture }),
                  let navigation = navigationController, navigation.topViewController === owner,
                  navigation.viewControllers.count > 1, navigation.transitionCoordinator == nil,
                  navigation.presentedViewController == nil else { return false }
            return true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            #if DEBUG && targetEnvironment(simulator)
            NativeBack49State.shared.beginCalls += 1
            #endif
            guard eligible(gestureRecognizer) else { return false }
            if let pan = gestureRecognizer as? UIPanGestureRecognizer, let view = pan.view {
                let velocity = pan.velocity(in: view)
                let returning = view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -velocity.x : velocity.x
                guard returning > abs(velocity.y) else { return false }
            }
            // The default delegate rejects hidden native back buttons. The
            // gesture still drives UIKit's original interactive pop action.
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard eligible(gestureRecognizer), let view = gestureRecognizer.view,
                  touch.type == .direct, touch.view?.isDescendant(of: view) == true else { return false }
            let point = touch.location(in: view)
            let distance = view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? view.bounds.maxX - point.x : point.x - view.bounds.minX
            let allowed = distance >= 0 && distance <= 24
            #if DEBUG && targetEnvironment(simulator)
            NativeBack49State.shared.receiveCalls += 1
            NativeBack49State.shared.lastReceiveAllowed = allowed
            #endif
            return allowed
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
            let allowed = eligible(gestureRecognizer) && event.type == .touches
            #if DEBUG && targetEnvironment(simulator)
            NativeBack49State.shared.eventCalls += 1
            NativeBack49State.shared.lastEventAllowed = allowed
            #endif
            return allowed
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            false
        }
        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            false
        }
        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            // Once the leading-edge touch is accepted, grid taps/scrolling
            // wait for the return pan. Center touches never enter this path.
            guard eligible(gesture), !bindings.contains(where: { $0.gesture === other }),
                  let view = navigationController?.view, let otherView = other.view else { return false }
            return otherView === view || otherView.isDescendant(of: view)
        }

        private func recordQA(_ controller: UINavigationController) {
            #if DEBUG && targetEnvironment(simulator)
            guard CollectionPagingQA.enabled, ProcessInfo.processInfo.arguments.contains("--qa-style49") else { return }
            NativeBack49State.shared.snapshot = { [weak controller, weak self] in
                guard let controller, #available(iOS 26.0, *) else { return }
                let state = NativeBack49State.shared
                let edge = controller.interactivePopGestureRecognizer
                let value = "depth=\(controller.viewControllers.count);nativeBackHidden=\(controller.topViewController?.navigationItem.hidesBackButton == true);edgeSwipe=\(edge?.isEnabled == true);ownDelegate=\(edge?.delegate === self);gestureState=\(edge?.state.rawValue ?? -1);beginCalls=\(state.beginCalls);receiveCalls=\(state.receiveCalls);receiveAllowed=\(state.lastReceiveAllowed);eventCalls=\(state.eventCalls);eventAllowed=\(state.lastEventAllowed);transition=\(controller.transitionCoordinator != nil);gestureView=\(edge?.view != nil);gestureInWindow=\(edge?.view?.window != nil);gestureWidth=\(Int(edge?.view?.bounds.width ?? -1));gestureViewEnabled=\(edge?.view?.isUserInteractionEnabled == true);navInWindow=\(controller.view.window != nil);edgeKind=\(edge is UIScreenEdgePanGestureRecognizer);edges=\((edge as? UIScreenEdgePanGestureRecognizer)?.edges.rawValue ?? 0);contentEnabled=\(controller.interactiveContentPopGestureRecognizer?.isEnabled == true);contentState=\(controller.interactiveContentPopGestureRecognizer?.state.rawValue ?? -1);gestureViewHidden=\(edge?.view?.isHidden == true);navHidden=\(controller.view.isHidden)"
                if NativeBack49State.shared.value != value { NativeBack49State.shared.value = value }
            }
            #endif
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
@MainActor private final class NativeBack49State: ObservableObject {
    static let shared = NativeBack49State()
    @Published var value = "notObserved"
    var snapshot: (() -> Void)?
    var beginCalls = 0
    var receiveCalls = 0
    var lastReceiveAllowed = false
    var eventCalls = 0
    var lastEventAllowed = false
}
private struct NativeBack49Readback: View {
    @ObservedObject private var state = NativeBack49State.shared
    var body: some View {
        Text(state.value).font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
            .accessibilityIdentifier("navigation.qa49").accessibilityValue(state.value)
            .task {
                while !Task.isCancelled {
                    state.snapshot?()
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                }
            }
    }
}
#endif

extension View {
    /// Apply once outside the root navigation and all presentations.
    func appRootAppearance() -> some View { modifier(AppRootAppearance()) }
    /// Ordinary navigation and sheets retain this theme even when opened over media.
    func ordinaryAppearance() -> some View { modifier(OrdinaryAppearance()) }
    /// Install exactly once at a navigation destination's root, never on a
    /// reusable content component such as MediaGrid or CollectionAccessView.
    func appNavigationBack() -> some View { modifier(FlatNavigationBack()) }
}
