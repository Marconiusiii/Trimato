import AVFoundation
import os

/// Pull samples only when the native writer asks for them. Each input owns a serial queue.
nonisolated final class AssetSamplePump: @unchecked Sendable {
    private let queue: DispatchQueue
    private let cancellation = OSAllocatedUnfairLock(initialState: false)
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let output: AVAssetReaderOutput
    private let sessionStart: CMTime
    private let duration: Double
    private let progress: (@MainActor @Sendable (Double) -> Void)?
    // The queue exclusively owns the following state.
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false
    private var monitor: DispatchSourceTimer?
    private let progressClosed = OSAllocatedUnfairLock(initialState: false)
    private var lastProgress = ContinuousClock.now - .seconds(1)

    init(reader: AVAssetReader, writer: AVAssetWriter, input: AVAssetWriterInput,
         output: AVAssetReaderOutput, start: CMTime, duration: Double,
         progress: (@MainActor @Sendable (Double) -> Void)? = nil,
         queue: DispatchQueue = DispatchQueue(label: "com.marconius.trimato.export-input", qos: .userInitiated)) {
        self.queue = queue
        self.reader = reader; self.writer = writer; self.input = input; self.output = output
        self.sessionStart = start; self.duration = duration; self.progress = progress
    }

    @concurrent
    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    guard !self.cancelled else { continuation.resume(throwing: CancellationError()); return }
                    self.continuation = continuation
                    let monitor = DispatchSource.makeTimerSource(queue: self.queue)
                    monitor.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
                    monitor.setEventHandler { [weak self] in self?.checkFailure() }
                    self.monitor = monitor
                    monitor.resume()
                    self.input.requestMediaDataWhenReady(on: self.queue) { [weak self] in self?.appendAvailable() }
                }
            }
        } onCancel: {
            self.cancellation.withLock { $0 = true }
            self.queue.async {
                self.cancelled = true
                self.reader.cancelReading()
                self.writer.cancelWriting()
                self.finish(.failure(CancellationError()))
            }
        }
    }

    private func appendAvailable() {
        guard continuation != nil else { return }
        while input.isReadyForMoreMediaData {
            if cancellation.withLock({ $0 }) {
                cancelled = true
                reader.cancelReading(); writer.cancelWriting()
                finish(.failure(CancellationError()))
                return
            }
            guard !cancelled, writer.status == .writing, reader.status != .failed else { checkFailure(); return }
            guard let sample = output.copyNextSampleBuffer() else {
                if reader.status == .failed { checkFailure(); return }
                input.markAsFinished()
                finish(.success(()))
                return
            }
            guard input.append(sample) else { checkFailure(force: true); return }
            if let progress, lastProgress.duration(to: .now) >= .milliseconds(200) {
                lastProgress = .now
                let elapsed = (CMSampleBufferGetPresentationTimeStamp(sample) - sessionStart).seconds
                let value = min(max(elapsed / duration, 0), 0.99)
                let closed = progressClosed
                Task { @MainActor in
                    guard !closed.withLock({ $0 }) else { return }
                    progress(value)
                }
            }
        }
    }

    private func checkFailure(force: Bool = false) {
        if cancelled || reader.status == .cancelled || writer.status == .cancelled {
            finish(.failure(CancellationError()))
        } else if force || reader.status == .failed || writer.status == .failed {
            let detail = (writer.error ?? reader.error).map { $0.localizedDescription }
                ?? "The media encoder stopped writing."
            finish(.failure(ProjectExporter.ExportError.encodingFailed(detail)))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        progressClosed.withLock { $0 = true }
        monitor?.cancel(); monitor = nil
        continuation.resume(with: result)
    }
}
