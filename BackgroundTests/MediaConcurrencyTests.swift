import Foundation
import Testing
@testable import TrimatoMediaSupport

@Suite struct MediaConcurrencyTests {
    @Test func queuedPreviewTakesPriorityAndCancelledJobIsRemoved() async throws {
        let scheduler = MediaJobScheduler()
        try await scheduler.acquire(.render, priority: .background)
        let background = Task { try await scheduler.acquire(.render, priority: .background) }
        while await scheduler.queuedCount < 1 { await Task.yield() }
        let preview = Task { try await scheduler.acquire(.render, priority: .interactive) }
        while await scheduler.queuedCount < 2 { await Task.yield() }
        let cancelled = Task { try await scheduler.acquire(.inspection, priority: .background) }
        try await cancelled.value
        let waiting = Task { try await scheduler.acquire(.inspection, priority: .background) }
        while await scheduler.queuedCount < 3 { await Task.yield() }
        waiting.cancel()
        do { try await waiting.value; Issue.record("Cancelled inspection was granted") } catch is CancellationError { }
        await scheduler.release(.render)
        try await preview.value
        #expect(await scheduler.queuedCount == 1)
        await scheduler.release(.render)
        try await background.value
        await scheduler.release(.render)
        await scheduler.release(.inspection)
    }
    @Test func inspectionDoesNotWaitForRender() async throws {
        let scheduler = MediaJobScheduler()
        try await scheduler.acquire(.render, priority: .background)
        try await scheduler.acquire(.inspection, priority: .interactive)
        await scheduler.release(.inspection)
        await scheduler.release(.render)
    }
    @Test func workerTimeoutDoesNotBlockMainActorOrStartOverlappingWork() async throws {
        let worker = SerialMediaWorker(label: "trimato.test.worker")
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let work = Task {
            try await worker.run(timeout: 0.1) {
                started.signal(); gate.wait(); return 1
            }
        }
        // Polling is off the main actor; the framework stand-in blocks only its own worker.
        _ = await Task.detached { started.wait(timeout: .now() + 2) }.value
        var timedOut = false
        do { _ = try await work.value } catch is WorkerTimeout { timedOut = true }
        #expect(timedOut)
        let mainActorResponded = await MainActor.run { true }
        #expect(mainActorResponded)
        let second = Task { try await worker.run(timeout: 0.1) { 2 } }
        do { _ = try await second.value; Issue.record("Overlapping worker operation ran") } catch is WorkerTimeout { }
        gate.signal()
        let recovered = try await worker.run { 3 }
        #expect(recovered == 3)
    }
    @Test func cancellationReturnsBeforeBlockingWorkCompletes() async throws {
        let worker = SerialMediaWorker(label: "trimato.test.cancel")
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let work = Task { try await worker.run { started.signal(); gate.wait(); return 1 } }
        _ = await Task.detached { started.wait(timeout: .now() + 2) }.value
        work.cancel()
        do { _ = try await work.value; Issue.record("Cancellation was ignored") } catch is CancellationError { }
        gate.signal()
        #expect(try await worker.run { 2 } == 2)
    }
}
