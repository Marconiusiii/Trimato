import AVFoundation

nonisolated enum RecordingCuePlayer {
    static func buffer(start: Bool) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9_600),
              let samples = buffer.floatChannelData?[0] else { throw AudioCaptureError.message("The recording cue could not be prepared.") }
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) {
            let time = Double(index) / 48_000
            let frequency = start ? (time < 0.1 ? 660.0 : 880.0) : (time < 0.1 ? 880.0 : 660.0)
            let local = time.truncatingRemainder(dividingBy: 0.1)
            let envelope = min(1, local / 0.008, (0.1 - local) / 0.008)
            samples[index] = Float(0.16 * max(0, envelope) * sin(2 * .pi * frequency * time))
        }
        return buffer
    }
}

/// Audio Queue can report "not running" before startup. Buffer consumption must
/// be observed before requesting a graceful stop and waiting for output to drain.
nonisolated final class RecordingCueCompletion: @unchecked Sendable {
    private let consumed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock(); consumed.signal() }
    func reset() { lock.lock(); cancelled = false; lock.unlock() }
    private func checkCancellation() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
    func bufferConsumed() { consumed.signal() }

    func play(timeout: TimeInterval = 3, start: () throws -> Void,
              drain: () throws -> Void, isRunning: () throws -> Bool) throws {
        while consumed.wait(timeout: .now()) == .success { }
        try checkCancellation()
        let deadline = Date().addingTimeInterval(timeout)
        try start()
        guard consumed.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success else {
            throw AudioCaptureError.message("The recording cue did not play on the selected output.")
        }
        try checkCancellation()
        try drain()
        while try isRunning() {
            try checkCancellation()
            guard Date() < deadline else {
                throw AudioCaptureError.message("The recording cue did not finish on the selected output.")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}
