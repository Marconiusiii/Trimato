import Foundation

/// A blocking framework operation owns this queue until it actually returns.
/// Cancellation releases its caller, not the underlying framework object.
nonisolated final class SerialMediaWorker: @unchecked Sendable {
    private let queue: DispatchQueue
    init(label: String) { queue = DispatchQueue(label: label, qos: .userInitiated) }

    func run<T: Sendable>(timeout: TimeInterval = 8, alwaysRun: Bool = false,
                         _ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let reply = WorkerReply<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reply.install(continuation)
                queue.async {
                    guard alwaysRun || reply.isPending else { return }
                    do { reply.finish(.success(try operation())) }
                    catch { reply.finish(.failure(error)) }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    reply.finish(.failure(WorkerTimeout()))
                }
            }
        } onCancel: { reply.finish(.failure(CancellationError())) }
    }
}

nonisolated struct WorkerTimeout: LocalizedError, Sendable {
    var errorDescription: String? { "The audio device did not respond in time. Stop recording and reconnect the device before trying again." }
}

nonisolated private final class WorkerReply<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    var isPending: Bool { lock.lock(); defer { lock.unlock() }; return result == nil }
    func install(_ value: CheckedContinuation<T, Error>) {
        lock.lock()
        if let result { lock.unlock(); value.resume(with: result) }
        else { continuation = value; lock.unlock() }
    }
    func finish(_ value: Result<T, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let pending = continuation; continuation = nil
        lock.unlock()
        pending?.resume(with: value)
    }
}
