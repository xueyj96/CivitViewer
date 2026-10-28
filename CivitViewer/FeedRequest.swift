import Foundation

/// A feed has exactly one upstream origin. The enum makes combinations such as
/// “following collection search” unrepresentable at the FeedStore boundary.
enum FeedSource: Hashable {
    case discovery
    case following
    case creator(Creator)
    case collection(Int)
    case search(MediaSearchTarget)
}

/// Identity of a loaded result set. Local visibility and asset de-duplication
/// policies are deliberately excluded: they reconcile the current raw rows.
struct FeedStoreRequestKey: Equatable {
    let identity: String
    let filter: FeedFilter
    let source: FeedSource
}

enum FeedLoadState: Equatable {
    case loaded
    case failed
    case ended
    case incomplete
}

/// A transport failure may be retried at its cursor. A protocol stall needs an
/// explicit from-start refresh; treating it as end or auto-retrying would hide
/// missing results or repeatedly request the same cursor.
enum FeedContinuationFailure: Equatable {
    case request(message: String, retryAfter: Date?)
    case stalled(message: String)

    var message: String {
        switch self { case .request(let message, _), .stalled(let message): message }
    }
    var retryAvailableAt: Date? {
        if case .request(_, let date) = self { return date }
        return nil
    }
    var requiresRestart: Bool {
        if case .stalled = self { return true }
        return false
    }
}

/// UI status is separate from the presence of currently displayed works. A
/// filtered scan can stay busy while those works and their focus remain intact.
enum FeedContinuationState: Equatable {
    case ready
    case loading
    case scanning
    case ended
    case failed(FeedContinuationFailure)

    var failure: FeedContinuationFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }
    var isLoading: Bool { self == .loading || self == .scanning }
    var retryAvailableAt: Date? { failure?.retryAvailableAt }
    var requiresRestart: Bool { failure?.requiresRestart ?? false }
}

struct FeedCommit: Equatable {
    enum Status: Equatable { case committed, unchanged, superseded, cancelled }
    let status: Status
    let key: FeedStoreRequestKey?
    let revision: Int
    let state: FeedLoadState?
    var didCommit: Bool { status == .committed }
}

/// Result of a transactional first-page restart. A failed restart leaves the
/// previously committed feed and its continuation untouched.
struct FeedRestartResult: Equatable {
    enum Status: Equatable { case committed, failedRetainingPrevious, unchanged, superseded, cancelled }
    let status: Status
    let key: FeedStoreRequestKey
    let revision: Int
    let error: String?
}

/// Synchronous cancellation signal for the current page owner. The signal is
/// written from task cancellation handlers and read on FeedStore's main actor.
final class FeedCancellationLease: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

