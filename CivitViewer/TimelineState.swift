import Foundation
import CryptoKit

/// Dismisses a logical resume anchor. Recording another exposure or video
/// progress must not manufacture a new prompt for the same work and scope.
struct TimelineCheckpointDismissals {
    static let defaultKey = "timelineCheckpointDismissals.v1"
    private let defaults: UserDefaults
    private let key: String
    init(defaults: UserDefaults = .standard, key: String = TimelineCheckpointDismissals.defaultKey) {
        self.defaults = defaults; self.key = key
    }
    func contains(owner: String, lane: HistoryLane, checkpoint: TimelineCheckpoint) -> Bool {
        let current = defaults.stringArray(forKey: key) ?? []
        if current.contains(TimelineStatePolicy.dismissalSignature(owner: owner, lane: lane, checkpoint: checkpoint)) { return true }
        // Build28 stored owner|lane|timestampBits|focus. Its timestamp changed
        // on every exposure. Honor a legacy close of the same account/lane/work
        // without rewriting or deleting the user's stored dismissals.
        return current.contains { value in
            let parts = value.split(separator: "|", omittingEmptySubsequences: false)
            return parts.count == 4 && parts[0] == owner && parts[1] == lane.rawValue &&
                UInt64(parts[2], radix: 16) != nil && Int(parts[3]) == checkpoint.focusedID
        }
    }
    func dismiss(owner: String, lane: HistoryLane, checkpoint: TimelineCheckpoint) {
        let signature = TimelineStatePolicy.dismissalSignature(owner: owner, lane: lane, checkpoint: checkpoint)
        var current = defaults.stringArray(forKey: key) ?? []
        current.removeAll { $0 == signature }
        current.append(signature)
        defaults.set(Array(current.suffix(100)), forKey: key)
    }
}

enum TimelineContinuationMode: Equatable {
    case savedCursor, rescanPending, rescanning, unavailable
}

enum TimelineRestoreState: Equatable {
    case browsing
    case restoring(UUID)
    case refreshing(UUID)
    case resumed(TimelineCheckpoint, TimelineContinuationMode)

    var isRestoring: Bool { if case .restoring = self { return true }; return false }
    var isRefreshing: Bool { if case .refreshing = self { return true }; return false }
    var isBusy: Bool { isRestoring || isRefreshing }
    var checkpoint: TimelineCheckpoint? { if case .resumed(let value, _) = self { return value }; return nil }
    var continuationUnavailable: Bool { if case .resumed(_, .unavailable) = self { return true }; return false }
}

struct TimelineNotice: Identifiable, Equatable {
    enum Severity: Equatable { case information, error }
    enum Recovery: Equatable { case restartFromStart }
    let id = UUID()
    let text: String
    let severity: Severity
    var recovery: Recovery? = nil
    var isError: Bool { severity == .error }
}

enum TimelinePagingMode: Equatable {
    case automatic
    case waitingForExplicitAction(FeedStoreRequestKey)
    var waitingKey: FeedStoreRequestKey? {
        if case .waitingForExplicitAction(let key) = self { return key }
        return nil
    }
    var isWaitingForExplicitAction: Bool { waitingKey != nil }
}

enum TimelineStatePolicy {
    static func continuationCoversLoadedTail(windowIDs: [Int], sourceTailID: Int?) -> Bool {
        sourceTailID.map(windowIDs.contains) ?? false
    }
    static func dismissalSignature(owner: String, lane: HistoryLane, checkpoint: TimelineCheckpoint) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let scope = (try? encoder.encode(checkpoint.filter)) ?? Data()
        let digest = SHA256.hash(data: scope).map { String(format: "%02x", $0) }.joined()
        return "\(owner)|\(lane.rawValue)|v2:\(digest)|\(checkpoint.focusedID)"
    }
}
