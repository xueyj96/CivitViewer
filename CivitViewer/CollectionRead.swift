import Foundation

/// One server read shared by passive indicators and the open collection picker.
/// Invalidating at a write boundary prevents an older response from publishing.
@MainActor
final class CollectionRead<Value> {
    private var generation = 0
    private var flight: (id: UUID, task: Task<Value, Error>)?

    func task(load: @escaping @MainActor () async throws -> Value,
              commit: @escaping @MainActor (Value) -> Void) -> Task<Value, Error> {
        if let flight { return flight.task }
        let id = UUID(), generation = self.generation
        let task = Task { @MainActor in
            defer { if self.flight?.id == id { self.flight = nil } }
            try Task.checkCancellation()
            let value = try await load()
            guard generation == self.generation else { throw CancellationError() }
            try Task.checkCancellation()
            commit(value)
            return value
        }
        flight = (id, task)
        return task
    }

    func invalidate() {
        generation += 1
        flight?.task.cancel()
        flight = nil
    }
}
