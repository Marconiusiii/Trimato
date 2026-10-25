import Foundation

/// Coalesce duplicate work while letting each consumer cancel without waiting for other consumers.
actor SharedMediaTasks<Key: Hashable & Sendable, Value: Sendable> {
    private struct Flight {
        let id: UUID
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<Value, Error>]
    }
    private var flights: [Key: Flight] = [:]

    func value(for key: Key, produce: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let consumer = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if flights[key] != nil {
                    flights[key]?.waiters[consumer] = continuation
                } else {
                    let id = UUID()
                    flights[key] = Flight(id: id, task: nil, waiters: [consumer: continuation])
                    flights[key]?.task = Task {
                        do {
                            let value = try await produce()
                            try Task.checkCancellation()
                            finish(key, id: id, result: .success(value))
                        } catch { finish(key, id: id, result: .failure(error)) }
                    }
                }
            }
        } onCancel: { Task { await self.cancel(key, consumer: consumer) } }
    }

    private func finish(_ key: Key, id: UUID, result: Result<Value, Error>) {
        guard flights[key]?.id == id, let flight = flights.removeValue(forKey: key) else { return }
        for continuation in flight.waiters.values { continuation.resume(with: result) }
    }

    private func cancel(_ key: Key, consumer: UUID) {
        guard let continuation = flights[key]?.waiters.removeValue(forKey: consumer) else { return }
        if flights[key]?.waiters.isEmpty == true {
            let task = flights.removeValue(forKey: key)?.task
            task?.cancel()
        }
        continuation.resume(throwing: CancellationError())
    }
}
