import Foundation

nonisolated enum MediaJobPriority: Int, Hashable, Sendable { case background, interactive }
nonisolated enum MediaJobContext {
    @TaskLocal static var priority: MediaJobPriority = .background
}

/// A short inspection can run beside one heavy render. Waiting previews run
/// before background renders; active jobs retain ownership until the process exits.
actor MediaJobScheduler {
    static let shared = MediaJobScheduler()
    enum Lane: Hashable, Sendable { case inspection, analysis, render }
    private struct Waiter {
        let id: UUID
        let lane: Lane
        let priority: MediaJobPriority
        let continuation: CheckedContinuation<Void, Error>
    }
    private var busy: [Lane: Int] = [:]
    private var backgroundRenders = 0
    private var waiters: [Waiter] = []
    private let renderCapacity: Int
    private let inspectionCapacity: Int
    var queuedCount: Int { waiters.count }

    init(renderCapacity: Int? = nil, inspectionCapacity: Int = 2) {
        self.inspectionCapacity = max(1, inspectionCapacity)
        let machine = ProcessInfo.processInfo
        self.renderCapacity = max(1, renderCapacity ??
            (machine.activeProcessorCount >= 8 && machine.physicalMemory >= 16 * 1_024 * 1_024 * 1_024 ? 2 : 1))
    }

    func acquire(_ lane: Lane, priority: MediaJobPriority) async throws {
        try Task.checkCancellation()
        if canStart(lane, priority: priority) { occupy(lane, priority: priority); return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append(Waiter(id: id, lane: lane, priority: priority, continuation: continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }

    func release(_ lane: Lane, priority: MediaJobPriority = .background) {
        busy[lane, default: 0] = max(0, busy[lane, default: 0] - 1)
        if lane == .render, priority == .background { backgroundRenders = max(0, backgroundRenders - 1) }
        while true {
            let eligible = waiters.indices.filter { canStart(waiters[$0].lane, priority: waiters[$0].priority) }
            guard let index = eligible.first(where: { waiters[$0].priority == .interactive }) ?? eligible.first else { return }
            let waiter = waiters.remove(at: index)
            occupy(waiter.lane, priority: waiter.priority)
            waiter.continuation.resume()
        }
    }

    private func canStart(_ lane: Lane, priority: MediaJobPriority) -> Bool {
        switch lane {
        case .inspection: busy[lane, default: 0] < inspectionCapacity
        case .analysis: busy[lane, default: 0] < 1
        case .render: busy[lane, default: 0] < renderCapacity && (priority == .interactive || backgroundRenders == 0)
        }
    }

    private func occupy(_ lane: Lane, priority: MediaJobPriority) {
        busy[lane, default: 0] += 1
        if lane == .render, priority == .background { backgroundRenders += 1 }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
