import Foundation

nonisolated enum MediaJobPriority: Int, Sendable { case background, interactive }
nonisolated enum MediaJobContext {
    @TaskLocal static var priority: MediaJobPriority = .background
}

/// A short inspection can run beside one heavy render. Waiting previews run
/// before background renders; active jobs retain ownership until the process exits.
actor MediaJobScheduler {
    static let shared = MediaJobScheduler()
    enum Lane: Sendable { case inspection, render }
    private struct Waiter {
        let id: UUID
        let lane: Lane
        let priority: MediaJobPriority
        let continuation: CheckedContinuation<Void, Error>
    }
    private var inspectionBusy = false
    private var renderBusy = false
    private var waiters: [Waiter] = []
    var queuedCount: Int { waiters.count }

    func acquire(_ lane: Lane, priority: MediaJobPriority) async throws {
        try Task.checkCancellation()
        if lane == .inspection ? !inspectionBusy : !renderBusy {
            occupy(lane, true); return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append(Waiter(id: id, lane: lane, priority: priority, continuation: continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func release(_ lane: Lane) {
        let candidates = waiters.indices.filter { waiters[$0].lane == lane }
        guard let index = candidates.first(where: { waiters[$0].priority == .interactive }) ?? candidates.first else {
            occupy(lane, false); return
        }
        waiters.remove(at: index).continuation.resume()
    }
    private func occupy(_ lane: Lane, _ value: Bool) {
        if lane == .inspection { inspectionBusy = value } else { renderBusy = value }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
