import Foundation

enum ViewingOrientation: String, Codable, CaseIterable, Sendable {
    case portrait
    case landscapeLeft
    case landscapeRight

    var toggled: ViewingOrientation { self == .portrait ? .landscapeRight : .portrait }
}

struct ViewingOrientationScope: Equatable, Sendable {
    let id: UUID
    let captured: ViewingOrientation
    var manualTarget: ViewingOrientation?
    var effectiveLock: ViewingOrientation { manualTarget ?? captured }
}

enum ViewingOrientationMask: Equatable, Sendable {
    case portrait
    case landscapeLeft
    case landscapeRight
    case allButUpsideDown
}

struct ViewingOrientationPolicy: Equatable, Sendable {
    private(set) var automatic: Bool
    private(set) var scopes: [ViewingOrientationScope] = []

    init(automatic: Bool = false) { self.automatic = automatic }

    var supportedMask: ViewingOrientationMask {
        if automatic { return .allButUpsideDown }
        switch scopes.last?.effectiveLock ?? .portrait {
        case .portrait: return .portrait
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        }
    }

    var isViewerActive: Bool { !scopes.isEmpty }

    mutating func setAutomatic(_ enabled: Bool) { automatic = enabled }

    mutating func beginViewer(_ id: UUID, actual: ViewingOrientation) {
        guard !scopes.contains(where: { $0.id == id }) else { return }
        scopes.append(ViewingOrientationScope(id: id, captured: actual, manualTarget: nil))
    }

    mutating func endViewer(_ id: UUID) {
        scopes.removeAll { $0.id == id }
    }

    mutating func toggleViewer(actual: ViewingOrientation) -> ViewingOrientation? {
        guard let index = scopes.indices.last else { return nil }
        let target = actual.toggled
        scopes[index].manualTarget = target
        return target
    }
}

struct ViewingOrientationRequestTracker {
    private(set) var revision = 0
    private var rollbackPolicy: ViewingOrientationPolicy?

    mutating func begin(rollbackOnFailure: ViewingOrientationPolicy? = nil) -> Int {
        revision += 1
        rollbackPolicy = rollbackOnFailure
        return revision
    }

    mutating func invalidate() { _ = begin() }

    mutating func reject(_ request: Int, policy: inout ViewingOrientationPolicy) -> Bool {
        guard request == revision else { return false }
        if let rollbackPolicy { policy = rollbackPolicy }
        self.rollbackPolicy = nil
        return true
    }
}

final class ViewingOrientationSettings {
    static let storageKey = "civitviewer.automaticRotation"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var automatic: Bool {
        get { defaults.object(forKey: Self.storageKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Self.storageKey) }
    }
}

#if canImport(UIKit)
import UIKit
import Combine

@MainActor final class ViewingOrientationController: ObservableObject {
    static let shared = ViewingOrientationController()

    @Published private(set) var automatic: Bool
    @Published private(set) var message: String?
    private let settings: ViewingOrientationSettings
    private var policy: ViewingOrientationPolicy
    private var geometryRequests = ViewingOrientationRequestTracker()

    var supportedOrientations: UIInterfaceOrientationMask {
        switch policy.supportedMask {
        case .portrait: .portrait
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        case .allButUpsideDown: .allButUpsideDown
        }
    }

    init(settings: ViewingOrientationSettings = ViewingOrientationSettings()) {
        self.settings = settings
        let value = settings.automatic
        self.automatic = value
        self.policy = ViewingOrientationPolicy(automatic: value)
    }

    func setAutomatic(_ enabled: Bool) {
        guard automatic != enabled else { return }
        automatic = enabled
        settings.automatic = enabled
        policy.setAutomatic(enabled)
        message = nil
        applyPolicy(requestGeometry: !enabled)
    }

    func beginViewer(_ id: UUID) {
        let previous = policy
        policy.beginViewer(id, actual: currentOrientation() ?? .portrait)
        guard previous != policy else { return }
        applyPolicy(requestGeometry: !automatic)
    }

    func endViewer(_ id: UUID) {
        let previous = policy
        policy.endViewer(id)
        guard previous != policy else { return }
        applyPolicy(requestGeometry: !automatic)
    }

    func toggleViewerOrientation() {
        let previous = policy
        guard let scene = activeScene(), let actual = orientation(scene.interfaceOrientation),
              let target = policy.toggleViewer(actual: actual) else {
            message = "当前无法更改画面方向。"
            return
        }
        message = nil
        applyPolicy(requestGeometry: true, sceneOverride: scene, target: target, rollbackOnFailure: previous)
    }

    func refreshSupportedOrientations() {
        geometryRequests.invalidate()
        updateControllers()
    }

    private func applyPolicy(requestGeometry: Bool, sceneOverride: UIWindowScene? = nil, target: ViewingOrientation? = nil,
                             rollbackOnFailure: ViewingOrientationPolicy? = nil) {
        let revision = geometryRequests.begin(rollbackOnFailure: requestGeometry ? rollbackOnFailure : nil)
        updateControllers()
        guard requestGeometry else { return }
        guard let scene = sceneOverride ?? activeScene() else {
            finishGeometryRequest(revision: revision, message: "当前无法更改画面方向。")
            return
        }
        guard #available(iOS 16.0, *) else {
            finishGeometryRequest(revision: revision, message: "当前系统暂不支持更改画面方向。")
            return
        }
        let mask: UIInterfaceOrientationMask
        if let target {
            switch target {
            case .portrait: mask = .portrait
            case .landscapeLeft: mask = .landscapeLeft
            case .landscapeRight: mask = .landscapeRight
            }
        } else {
            mask = supportedOrientations
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] _ in
            Task { @MainActor in
                self?.finishGeometryRequest(revision: revision, message: "系统未接受画面方向请求；设备旋转锁定设置保持不变。")
            }
        }
    }

    private func finishGeometryRequest(revision: Int, message: String) {
        guard geometryRequests.reject(revision, policy: &policy) else { return }
        updateControllers()
        self.message = message
    }

    private func activeScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive && $0.windows.contains(where: \.isKeyWindow) }
    }

    private func currentOrientation() -> ViewingOrientation? {
        guard let scene = activeScene() else { return nil }
        return orientation(scene.interfaceOrientation)
    }

    private func orientation(_ value: UIInterfaceOrientation) -> ViewingOrientation? {
        switch value {
        case .portrait, .portraitUpsideDown: .portrait
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: nil
        }
    }

    private func updateControllers() {
        guard let window = activeScene()?.windows.first(where: \.isKeyWindow) else { return }
        func update(_ controller: UIViewController?) {
            guard let controller else { return }
            if #available(iOS 16.0, *) { controller.setNeedsUpdateOfSupportedInterfaceOrientations() }
            update(controller.presentedViewController)
        }
        update(window.rootViewController)
    }
}
#endif
