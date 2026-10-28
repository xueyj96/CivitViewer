import Foundation

@main struct ViewingOrientationChecks {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1; precondition(condition(), message)
        }

        let suite = "ViewingOrientationChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ViewingOrientationSettings(defaults: defaults)
        check(!settings.automatic, "Automatic rotation defaults off")
        settings.automatic = true
        check(ViewingOrientationSettings(defaults: defaults).automatic, "Automatic rotation persists locally")
        settings.automatic = false
        check(!settings.automatic, "Automatic rotation can be disabled without another selector state")

        var policy = ViewingOrientationPolicy()
        check(policy.supportedMask == .portrait, "Default locked policy permits portrait")
        let viewer = UUID()
        policy.beginViewer(viewer, actual: .landscapeLeft)
        check(policy.supportedMask == .landscapeLeft, "Viewer scope captures exact landscape side when automatic rotation is off")
        let firstTarget = policy.toggleViewer(actual: .landscapeLeft)
        check(firstTarget == .portrait && policy.supportedMask == .portrait && !policy.automatic, "Manual toggle locks portrait without changing the automatic setting")
        let secondTarget = policy.toggleViewer(actual: .portrait)
        check(secondTarget == .landscapeRight && policy.supportedMask == .landscapeRight && !policy.automatic, "Manual toggle uses actual orientation and directly switches back")
        policy.endViewer(viewer)
        check(policy.supportedMask == .portrait && !policy.isViewerActive, "Leaving viewer restores the non-viewer portrait policy")

        let exactSideViewer = UUID()
        policy.beginViewer(exactSideViewer, actual: .landscapeRight)
        check(policy.supportedMask == .landscapeRight, "Locked landscape preserves right-side orientation instead of permitting a 180-degree flip")
        policy.endViewer(exactSideViewer)

        policy.setAutomatic(true)
        let automaticViewer = UUID()
        policy.beginViewer(automaticViewer, actual: .portrait)
        check(policy.supportedMask == .allButUpsideDown, "Automatic setting allows normal OS-supported orientations")
        _ = policy.toggleViewer(actual: .portrait)
        check(policy.automatic && policy.supportedMask == .allButUpsideDown, "Manual request under automatic mode does not persist a forced orientation")
        policy.endViewer(automaticViewer)
        check(policy.supportedMask == .allButUpsideDown, "Leaving viewer restores automatic policy")

        policy.setAutomatic(false)
        let parent = UUID(), child = UUID()
        policy.beginViewer(parent, actual: .portrait)
        _ = policy.toggleViewer(actual: .portrait)
        policy.beginViewer(child, actual: .portrait)
        check(policy.supportedMask == .portrait, "Nested viewer uses the active child scope")
        policy.endViewer(parent)
        check(policy.isViewerActive && policy.supportedMask == .portrait, "Ending parent out of order does not discard active child")
        _ = policy.toggleViewer(actual: .portrait)
        check(policy.supportedMask == .landscapeRight, "Active nested viewer can manually request landscape")
        policy.endViewer(child)
        check(!policy.isViewerActive && policy.supportedMask == .portrait, "Ending final child restores the base settings policy")

        let parentRestore = UUID(), childRestore = UUID()
        policy.beginViewer(parentRestore, actual: .portrait)
        _ = policy.toggleViewer(actual: .portrait)
        policy.beginViewer(childRestore, actual: .portrait)
        policy.endViewer(childRestore)
        check(policy.supportedMask == .landscapeRight, "Ending child restores the still-active parent manual orientation")
        policy.endViewer(parentRestore)
        check(policy.supportedMask == .portrait, "Ending parent restores base orientation policy")

        var rollbackPolicy = ViewingOrientationPolicy()
        let rollbackViewer = UUID()
        rollbackPolicy.beginViewer(rollbackViewer, actual: .portrait)
        let prior = rollbackPolicy
        var requests = ViewingOrientationRequestTracker()
        let rejectedRequest = requests.begin(rollbackOnFailure: prior)
        _ = rollbackPolicy.toggleViewer(actual: .portrait)
        check(rollbackPolicy.supportedMask == .landscapeRight, "Manual request temporarily applies its requested exact mask")
        check(requests.reject(rejectedRequest, policy: &rollbackPolicy) && rollbackPolicy == prior, "Rejected geometry request restores the previous policy")
        let staleRequest = requests.begin(rollbackOnFailure: prior)
        let newerRequest = requests.begin()
        _ = rollbackPolicy.toggleViewer(actual: .portrait)
        check(!requests.reject(staleRequest, policy: &rollbackPolicy) && rollbackPolicy.supportedMask == .landscapeRight, "Late rejection cannot roll back a newer user orientation request")
        check(requests.reject(newerRequest, policy: &rollbackPolicy), "Current request rejection is accepted by revision tracker")
        print("ViewingOrientationChecks: \(checks) local policy assertions passed")
    }
}
