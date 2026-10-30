import Foundation

enum ImageLoadError: LocalizedError {
    case queueFull, decode, lowSpace, missingLocal, cacheWrite, animationLimit
    var errorDescription: String? {
        switch self {
        case .queueFull: "图片任务较多，请稍后重试"
        case .decode: "封面格式无法读取"
        case .lowSpace: "手机可用空间不足"
        case .missingLocal: "本地图片暂不可用"
        case .cacheWrite: "图片暂时无法保存"
        case .animationLimit: "动图超过本机播放上限，请在原站查看"
        }
    }
}

/// FIFO admission rather than treating a fifth visible thumbnail as a failure.
/// Shared requests own permits; cancellation of their final consumer cancels a
/// queued request without consuming a download slot.
@MainActor final class MediaLoadQueue {
    enum Priority: Equatable { case foreground, background }
    private struct Waiting { let id: UUID; let priority: Priority; let continuation: CheckedContinuation<Void, Error> }
    private let limit: Int
    private let backgroundLimit: Int
    private let foregroundLimit: Int
    private let maximumWaiting: Int
    private var active: [UUID: Priority] = [:]
    private var waiting: [Waiting] = []
    var activeCount: Int { active.count }
    var waitingCount: Int { waiting.count }
    init(limit: Int = 4, maximumWaiting: Int = 64, backgroundLimit: Int? = nil, foregroundLimit: Int? = nil) {
        self.limit = max(1, limit)
        // The lane cap reserves capacity for foreground work when background
        // requests arrive first. The total limit still allows those slots to
        // fill when foreground requests are already present.
        let reservedBackgroundMaximum = max(1, self.limit - min(2, self.limit - 1))
        self.backgroundLimit = min(reservedBackgroundMaximum, max(1, backgroundLimit ?? self.limit))
        self.foregroundLimit = min(self.limit, max(1, foregroundLimit ?? self.limit))
        self.maximumWaiting = max(1, maximumWaiting)
    }
    func acquire(_ id: UUID, priority: Priority = .foreground) async throws {
        try Task.checkCancellation()
        if canAdmit(priority) { active[id] = priority; return }
        guard waiting.count < maximumWaiting else { throw ImageLoadError.queueFull }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let request = Waiting(id: id, priority: priority, continuation: continuation)
                if priority == .foreground, let firstBackground = waiting.firstIndex(where: { $0.priority == .background }) {
                    waiting.insert(request, at: firstBackground)
                } else { waiting.append(request) }
            }
        } onCancel: { Task { @MainActor in self.cancelWaiting(id) } }
        do { try Task.checkCancellation() } catch { release(id); throw error }
    }
    func release(_ id: UUID) {
        guard active.removeValue(forKey: id) != nil else { return }
        drain()
    }
    func promote(_ id: UUID) {
        setPriority(.foreground, for: id)
    }
    func setPriority(_ priority: Priority, for id: UUID) {
        // Reclassifying an existing permit never increases total active work.
        // Lane caps govern new admissions; an already-running shared transfer
        // may temporarily make a lane's active count exceed its admission cap.
        if active[id] != nil {
            active[id] = priority
            drain()
            return
        }
        guard let index = waiting.firstIndex(where: { $0.id == id }), waiting[index].priority != priority else { return }
        let value = waiting.remove(at: index)
        let changed = Waiting(id: value.id, priority: priority, continuation: value.continuation)
        if priority == .foreground, let firstBackground = waiting.firstIndex(where: { $0.priority == .background }) {
            waiting.insert(changed, at: firstBackground)
        } else if priority == .foreground {
            waiting.insert(changed, at: 0)
        } else {
            waiting.append(changed)
        }
        drain()
    }
    private func cancelWaiting(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        let value = waiting.remove(at: index); value.continuation.resume(throwing: CancellationError())
    }
    private func canAdmit(_ priority: Priority) -> Bool {
        guard active.count < limit else { return false }
        switch priority {
        case .foreground: return active.values.filter { $0 == .foreground }.count < foregroundLimit
        case .background: return active.values.filter { $0 == .background }.count < backgroundLimit
        }
    }
    private func drain() {
        while let index = waiting.firstIndex(where: { canAdmit($0.priority) }) {
            let next = waiting.remove(at: index); active[next.id] = next.priority; next.continuation.resume()
        }
    }
}
