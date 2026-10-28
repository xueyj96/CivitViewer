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
    private struct Waiting { let id: UUID; let continuation: CheckedContinuation<Void, Error> }
    private let limit: Int
    private let maximumWaiting: Int
    private var active = Set<UUID>()
    private var waiting: [Waiting] = []
    var activeCount: Int { active.count }
    var waitingCount: Int { waiting.count }
    init(limit: Int = 4, maximumWaiting: Int = 64) { self.limit = max(1, limit); self.maximumWaiting = max(1, maximumWaiting) }
    func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        if active.count < limit { active.insert(id); return }
        guard waiting.count < maximumWaiting else { throw ImageLoadError.queueFull }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in waiting.append(.init(id: id, continuation: continuation)) }
        } onCancel: { Task { @MainActor in self.cancelWaiting(id) } }
        do { try Task.checkCancellation() } catch { release(id); throw error }
    }
    func release(_ id: UUID) {
        guard active.remove(id) != nil else { return }
        if !waiting.isEmpty {
            let next = waiting.removeFirst(); active.insert(next.id); next.continuation.resume()
        }
    }
    private func cancelWaiting(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        let value = waiting.remove(at: index); value.continuation.resume(throwing: CancellationError())
    }
}
