import Testing
@testable import Trimato

actor MediaWorkGate {
    var starts = 0
    var released = false
    func work() async throws -> Int {
        starts += 1
        while !released { try await Task.sleep(for: .milliseconds(5)) }
        return 42
    }
    func release() { released = true }
}

struct SharedMediaTasksTests {
    @Test func cancellingOneConsumerDoesNotWaitForOrCancelAnother() async throws {
        let work = SharedMediaTasks<String, Int>()
        let gate = MediaWorkGate()
        let first = Task { try await work.value(for: "source") { try await gate.work() } }
        while await gate.starts == 0 { await Task.yield() }
        let second = Task { try await work.value(for: "source") { try await gate.work() } }
        try await Task.sleep(for: .milliseconds(20))
        first.cancel()
        // This must finish even though the shared producer is still blocked for the second consumer.
        await #expect(throws: CancellationError.self) { _ = try await first.value }
        #expect(await gate.starts == 1)
        await gate.release()
        #expect(try await second.value == 42)
    }

    @Test func cancellingLastConsumerCancelsWorkAndAllowsImmediateRetry() async throws {
        let work = SharedMediaTasks<String, Int>()
        let gate = MediaWorkGate()
        let first = Task { try await work.value(for: "source") { try await gate.work() } }
        while await gate.starts == 0 { await Task.yield() }
        first.cancel()
        await #expect(throws: CancellationError.self) { _ = try await first.value }
        #expect(try await work.value(for: "source") { 7 } == 7)
    }
}
