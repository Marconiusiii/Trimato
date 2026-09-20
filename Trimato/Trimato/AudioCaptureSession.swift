import AVFoundation
import AudioToolbox
import Combine
#if DEBUG
import Synchronization
import os

/// Single audio-callback producer; observers read atomic counters only. No audio contents.
@available(macOS 15.0, *)
nonisolated final class AudioCaptureTiming: @unchecked Sendable {
    let callbacks = Atomic<UInt64>(0)
    let latestHostTime = Atomic<UInt64>(0)
    let largestHostGap = Atomic<UInt64>(0)
    let discontinuities = Atomic<UInt64>(0)
    private var expectedSampleTime: Double?

    func receive(hostTime: UInt64, sampleTime: Double?, frames: UInt32) {
        let previous = latestHostTime.load(ordering: .relaxed)
        if previous != 0, hostTime >= previous {
            let gap = hostTime - previous
            if gap > largestHostGap.load(ordering: .relaxed) {
                largestHostGap.store(gap, ordering: .relaxed)
            }
        }
        if let sampleTime, sampleTime.isFinite {
            if let expectedSampleTime, abs(sampleTime - expectedSampleTime) > 0.5 {
                discontinuities.wrappingAdd(1, ordering: .relaxed)
            }
            expectedSampleTime = sampleTime + Double(frames)
        } else {
            expectedSampleTime = nil
        }
        latestHostTime.store(hostTime, ordering: .relaxed)
        callbacks.wrappingAdd(1, ordering: .relaxed)
    }
}
#endif

nonisolated enum AudioCaptureError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

nonisolated struct AudioRecordingSummary: Equatable, Sendable {
    var frames: Int64 = 0
    var sampleRate: Double = 0
    var peak: Float = 0
    var clippedSamples: Int64 = 0
    var duration: Double { sampleRate > 0 ? Double(frames) / sampleRate : 0 }
    var peakDecibels: Double? { peak > 0 ? 20 * log10(Double(peak)) : nil }
}

// The hardware callback copies into a preallocated single-producer ring. It
// performs no file I/O, allocation, dispatch, or blocking lock acquisition.
nonisolated final class AudioCaptureWriter: @unchecked Sendable {
    private let ring: OpaquePointer
    private let queue = DispatchQueue(label: "com.marconius.trimato.recording-writer", qos: .userInitiated)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var file: AVAudioFile?
    private var summary = AudioRecordingSummary()
    private var failure: String?
    private let channel: Int
    private let sampleRate: Double
    private let inputChannels: Int
    private let buffer: AVAudioPCMBuffer
#if DEBUG
    // Keep the app's older deployment target; these temporary diagnostics run on macOS 15+.
    private let timing: AnyObject? = {
        if #available(macOS 15.0, *) { return AudioCaptureTiming() }
        return nil
    }()
    private let diagnosticID = UUID().uuidString
    private let diagnosticQueue = DispatchQueue(label: "com.marconius.trimato.capture-diagnostics", qos: .utility)
    private var diagnosticTimer: DispatchSourceTimer?
    private static let diagnosticLog = Logger(subsystem: "com.marconius.trimato", category: "Recording diagnostics")

    /// Polling is deliberately separate from both the hardware callback and disk writer.
    func startDiagnostics(input: AudioDeviceID, output: AudioDeviceID) {
        diagnosticEvent("input-opening")
        let timer = DispatchSource.makeTimerSource(queue: diagnosticQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self, #available(macOS 15.0, *), let timing = self.timing as? AudioCaptureTiming else { return }
            let state = self.snapshot()
            let last = timing.latestHostTime.load(ordering: .relaxed)
            let gap = timing.largestHostGap.load(ordering: .relaxed)
            let age = last == 0 ? -1 : AVAudioTime.seconds(forHostTime: mach_absolute_time() - last)
            let metadata = "id=\(self.diagnosticID) event=sample callbacks=\(timing.callbacks.load(ordering: .relaxed)) maxCallbackGapSeconds=\(AVAudioTime.seconds(forHostTime: gap)) lastCallbackAgeSeconds=\(age) sampleDiscontinuities=\(timing.discontinuities.load(ordering: .relaxed)) writtenFrames=\(state.0.frames) writerFailed=\(state.1 != nil) clientRate=\(self.sampleRate) clientChannels=\(self.inputChannels) input={\(Self.deviceFormat(input, input: true))} output={\(Self.deviceFormat(output, input: false))} defaultInput=\(AudioHardware.defaultDevice(input: true)) defaultOutput=\(AudioHardware.defaultDevice(input: false))"
            Self.diagnosticLog.info("\(metadata, privacy: .public)")
        }
        diagnosticTimer = timer
        timer.resume()
    }

    private static func deviceFormat(_ device: AudioDeviceID, input: Bool) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat,
            mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &format)
        return "device=\(device) status=\(status) rate=\(format.mSampleRate) channels=\(format.mChannelsPerFrame) format=\(format.mFormatID)"
    }

    private func diagnosticEvent(_ event: String) {
        Self.diagnosticLog.info("id=\(self.diagnosticID, privacy: .public) event=\(event, privacy: .public)")
    }
#endif

    init(url: URL, sampleRate: Double, channel: Int, bitDepth: Int, inputChannels: Int = 1) throws {
        guard sampleRate.isFinite, sampleRate > 0, channel >= 0, [16, 24].contains(bitDepth),
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65536),
              let ring = TCaptureCreate(16, 65536) else {
            throw AudioCaptureError.message("The microphone format is unsupported.")
        }
        self.ring = ring; self.buffer = buffer
        self.channel = channel; self.sampleRate = sampleRate; self.inputChannels = inputChannels
        summary.sampleRate = sampleRate
        do {
            file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: bitDepth,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch { throw error }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.drain() }
        self.timer = timer
        timer.resume()
    }

    deinit {
        timer?.cancel()
#if DEBUG
        diagnosticTimer?.cancel()
#endif
        TCaptureDestroy(ring)
    }
    var hasReceivedAudio: Bool { TCaptureReceived(ring) != 0 }
    var deliveryCount: UInt64 { TCaptureDeliveries(ring) }
    func begin() {
#if DEBUG
        diagnosticEvent("retaining-start")
#endif
        TCaptureBegin(ring)
    }
    func stopAccepting() { TCaptureStop(ring) }

    func receive(_ source: AVAudioPCMBuffer) {
        let valid = source.format.sampleRate == sampleRate && channel < Int(source.format.channelCount)
        let samples = valid ? (source.format.isInterleaved ? source.floatChannelData?[0].advanced(by: channel) : source.floatChannelData?[channel]) : nil
        TCapturePush(ring, samples, source.frameLength, UInt32(source.stride), samples == nil ? 0 : 1)
    }

    // Audio Queue delivers interleaved float PCM, converted by Core Audio from the device format.
    func receive(_ source: AudioQueueBufferRef, queue: AudioQueueRef, timestamp: AudioTimeStamp) {
#if DEBUG
        if #available(macOS 15.0, *), let timing = timing as? AudioCaptureTiming {
            let frameBytes = inputChannels * MemoryLayout<Float>.size
            timing.receive(hostTime: mach_absolute_time(),
                sampleTime: timestamp.mFlags.contains(.sampleTimeValid) ? timestamp.mSampleTime : nil,
                frames: frameBytes > 0 ? source.pointee.mAudioDataByteSize / UInt32(frameBytes) : 0)
        }
#endif
        receiveInterleaved(source.pointee.mAudioData, byteCount: Int(source.pointee.mAudioDataByteSize))
        let status = AudioQueueEnqueueBuffer(queue, source, 0, nil)
        if status != noErr { TCaptureDeviceError(ring, status) }
    }

    func receiveInterleaved(_ data: UnsafeRawPointer, byteCount: Int) {
        let frameBytes = inputChannels * MemoryLayout<Float>.size
        let valid = inputChannels > channel && frameBytes > 0 && byteCount >= 0 && byteCount % frameBytes == 0
        let samples = data.assumingMemoryBound(to: Float.self)
        TCapturePush(ring, valid ? samples.advanced(by: channel) : nil,
            valid ? UInt32(byteCount / frameBytes) : 0, UInt32(inputChannels), valid ? 1 : 0)
    }

    private func drain() {
        var count: UInt32 = 0
        while let samples = TCapturePeek(ring, &count) {
            buffer.frameLength = count
            buffer.floatChannelData![0].update(from: samples, count: Int(count))
            do {
                if let file {
                    try file.write(from: buffer)
                    var peak: Float = 0; var clipped: Int64 = 0
                    for index in 0..<Int(count) {
                        let magnitude = abs(samples[index]); peak = max(peak, magnitude)
                        if magnitude >= 1 { clipped += 1 }
                    }
                    lock.lock()
                    summary.frames += Int64(count)
                    summary.peak = max(summary.peak, peak); summary.clippedSamples += clipped
                    lock.unlock()
                }
            } catch {
                stopAccepting()
                lock.lock(); failure = "The recording could not be written: \(error.localizedDescription)"; lock.unlock()
            }
            TCaptureConsume(ring)
        }
    }

    func snapshot() -> (AudioRecordingSummary, String?) {
        lock.lock(); defer { lock.unlock() }
        let ringFailure = TCaptureFailure(ring)
        return (summary, failure ?? (ringFailure == 1 ? "The microphone format changed during recording." :
            ringFailure == 2 ? "Recording stopped because storage could not keep up. The captured audio is available for playback." :
            ringFailure == 3 ? "The input stopped accepting recording buffers (Core Audio \(TCaptureDeviceStatus(ring))). The captured audio is available for playback." : nil))
    }

    // Called on the capture worker, never on the interface or hardware callback.
    func finish() -> (AudioRecordingSummary, String?) {
        stopAccepting()
#if DEBUG
        diagnosticEvent("retaining-stop")
#endif
        while TCaptureActive(ring) != 0 { Thread.sleep(forTimeInterval: 0.001) }
        queue.sync { timer?.cancel(); timer = nil; drain(); file = nil }
#if DEBUG
        diagnosticQueue.sync {
            diagnosticTimer?.cancel(); diagnosticTimer = nil
            guard #available(macOS 15.0, *), let timing = timing as? AudioCaptureTiming else { return }
            let result = snapshot()
            Self.diagnosticLog.info("id=\(self.diagnosticID, privacy: .public) event=writer-finished frames=\(result.0.frames) failed=\(result.1 != nil) callbacks=\(timing.callbacks.load(ordering: .relaxed)) sampleDiscontinuities=\(timing.discontinuities.load(ordering: .relaxed))")
        }
#endif
        return snapshot()
    }
}

nonisolated struct AudioCaptureRequest: Sendable, Equatable {
    let inputDeviceID: AudioDeviceID
    let inputUID: String
    let outputDeviceID: AudioDeviceID
    let outputUID: String
    let channel: Int
    let bitDepth: Int
    var systemDefaultInput = false
    var systemDefaultOutput = false
}

nonisolated struct AudioCaptureResult: Sendable {
    var url: URL?
    var summary = AudioRecordingSummary()
    var error: String?
}

@MainActor
protocol AudioCaptureBackend: AnyObject {
    var isReady: Bool { get }
    var configurationChanged: (() -> Void)? { get set }
    var resolvedRoutes: (input: String, output: String)? { get }
    var preparationIssue: String? { get }
    func prepare(_ request: AudioCaptureRequest) async throws
    func settle() async throws
    func playStartCue() async throws
    func begin() async throws
    func progress() -> (AudioRecordingSummary, String?)
    func stopAccepting()
    func finish(playCue: Bool) async -> AudioCaptureResult
}

extension AudioCaptureBackend {
    var resolvedRoutes: (input: String, output: String)? { nil }
    var preparationIssue: String? { nil }
    func stopAccepting() { }
    func playStartCue() async throws { }
}

/// The UI-facing adapter reads only snapshots; all engine ownership stays on its worker.
@MainActor
private final class MicrophoneCaptureBackend: AudioCaptureBackend {
    var configurationChanged: (() -> Void)?
    private static let sharedWorker = SerialMediaWorker(label: "com.marconius.trimato.capture-device")
    private var worker: SerialMediaWorker { Self.sharedWorker }
    private let device = MicrophoneDevice()
    var isReady: Bool { device.isReady }
    var resolvedRoutes: (input: String, output: String)? { device.resolvedRoutes }
    var preparationIssue: String? { device.preparationIssue }
    func prepare(_ request: AudioCaptureRequest) async throws {
        try await worker.run { [device] in try device.prepare(request) }
    }
    func settle() async throws { try await worker.run { [device] in try device.settle() } }
    func playStartCue() async throws { try await worker.run { [device] in try device.playCue(start: true) } }
    func begin() async throws { try await worker.run { [device] in try device.begin() } }
    func progress() -> (AudioRecordingSummary, String?) { device.progress() }
    func stopAccepting() { device.stopAccepting() }
    func finish(playCue: Bool) async -> AudioCaptureResult {
        device.stopAccepting()
        do { return try await worker.run(alwaysRun: true) { [device] in device.finish(playCue: playCue) } }
        catch { return device.completedResult(error: error.localizedDescription) }
    }
}

nonisolated private final class MicrophoneDevice: @unchecked Sendable {
    // Only these snapshots are accessed outside the serial device worker.
    private let lock = NSLock()
    private var snapshotWriter: AudioCaptureWriter?
    private var completedRecording = AudioCaptureResult()
    func completedResult(error: String) -> AudioCaptureResult {
        lock.lock(); let result = completedRecording; lock.unlock()
        return AudioCaptureResult(url: result.url, summary: result.summary, error: error)
    }
    private var preparationDetail: String?
    var preparationIssue: String? { lock.lock(); defer { lock.unlock() }; return preparationDetail }
    private func preparationIssue(_ detail: String?) { lock.lock(); preparationDetail = detail; lock.unlock() }
    private var routeSnapshot: (input: String, output: String)?
    var resolvedRoutes: (input: String, output: String)? {
        lock.lock(); defer { lock.unlock() }; return routeSnapshot
    }
    private var stopRequested = false
    private var running = false
    private var inputQueue: AudioQueueRef?
    private var inputContext: Unmanaged<AudioCaptureWriter>?
    private var readyAfterDelivery: UInt64 = 0
    private var inputReadyAfter: TimeInterval = 0
    private var outputQueue: AudioQueueRef?
    private var cueContext: Unmanaged<RecordingCueCompletion>?
    private var cueSnapshot: RecordingCueCompletion?
    private var outputIsBluetooth = false
    private var writer: AudioCaptureWriter?
    private var request: AudioCaptureRequest?
    private var candidateURL: URL?
    private var recording = false
    private var setupRetries = 0

    var isReady: Bool {
        lock.lock(); let ready = running && ProcessInfo.processInfo.systemUptime >= inputReadyAfter; let writer = snapshotWriter; let baseline = readyAfterDelivery; lock.unlock()
        return ready && (writer?.deliveryCount ?? 0) > baseline
    }
    func progress() -> (AudioRecordingSummary, String?) {
        lock.lock(); let writer = snapshotWriter; lock.unlock()
        return writer?.snapshot() ?? (AudioRecordingSummary(), nil)
    }
    func stopAccepting() {
        lock.lock(); stopRequested = true; let writer = snapshotWriter; let cue = cueSnapshot; lock.unlock()
        writer?.stopAccepting()
        cue?.cancel()
    }
    private func publish(running: Bool, writer: AudioCaptureWriter?) {
        lock.lock(); self.running = running; snapshotWriter = writer; lock.unlock()
    }

    func prepare(_ request: AudioCaptureRequest) throws {
        _ = finish()
        guard inputQueue == nil, outputQueue == nil else {
            throw AudioCaptureError.message("The previous audio input has not finished closing. Reconnect the device before another recording.")
        }
        lock.lock(); stopRequested = false; readyAfterDelivery = 0; completedRecording = AudioCaptureResult(); lock.unlock()
        self.request = request
        setupRetries = 0
        // Opening is deferred to settle so a temporarily incomplete Bluetooth route can become ready.
    }

    func settle() throws {
        if let error = progress().1 { throw AudioCaptureError.message(error) }
        do { try openInputIfNeeded() }
        catch let error as AudioCaptureSetupError where error.canRetry && setupRetries < 3 {
            setupRetries += 1
            let pending = request
            _ = finish()
            request = pending
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private func openInputIfNeeded() throws {
        guard inputQueue == nil, let request else { return }
        let devices = AudioHardware.devices()
        let inputID = AudioHardware.defaultDevice(input: true)
        let outputID = AudioHardware.defaultDevice(input: false)
        guard let input = devices.first(where: {
            (request.systemDefaultInput ? $0.deviceID == inputID : $0.id == request.inputUID) && $0.inputChannels > 0
        }) else {
            preparationIssue(request.systemDefaultInput ? "No system default audio input is available." : "The selected audio input is unavailable. Check its connection or choose an input in Settings.")
            return
        }
        guard let output = devices.first(where: {
            (request.systemDefaultOutput ? $0.deviceID == outputID : $0.id == request.outputUID) && $0.outputChannels > 0
        }) else {
            preparationIssue("The recording cue output is unavailable. Check its connection or choose a playback device in Settings.")
            return
        }
        preparationIssue(nil)
        do {
            var property = AudioHardware.address(kAudioDevicePropertyTransportType)
            var transport: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(output.deviceID, &property, 0, nil, &size, &transport)
            outputIsBluetooth = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(transport)
        }
        lock.lock(); routeSnapshot = (input.id, output.id); lock.unlock()
        let rate = AudioHardware.sampleRate(input.deviceID)
        guard rate.isFinite, rate > 0 else { return }
        var format = try AudioCaptureConfiguration.format(sampleRate: rate, channels: input.inputChannels,
                                                         selectedChannel: request.channel)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Trimato-Recording-Test-\(UUID()).wav")
        candidateURL = url
        let writer = try AudioCaptureWriter(url: url, sampleRate: rate, channel: request.channel,
            bitDepth: request.bitDepth, inputChannels: input.inputChannels)
        self.writer = writer
#if DEBUG
        writer.startDiagnostics(input: input.deviceID, output: output.deviceID)
#endif
        var queue: AudioQueueRef?
        let context = Unmanaged.passRetained(writer)
        let created = AudioQueueNewInput(&format, { context, queue, buffer, timestamp, _, _ in
            guard let context else { return }
            Unmanaged<AudioCaptureWriter>.fromOpaque(context).takeUnretainedValue().receive(buffer, queue: queue, timestamp: timestamp.pointee)
        }, context.toOpaque(), nil, nil, 0, &queue)
        if created != noErr { context.release() }
        else { inputContext = context }
        try AudioCaptureConfiguration.check(created, operation: "Creating the recording input")
        guard let queue else {
            inputContext?.release(); inputContext = nil
            throw AudioCaptureError.message("Core Audio did not create a recording input.")
        }
        inputQueue = queue
        try AudioCaptureConfiguration.selectDevice(queue, uid: input.id,
            systemDefault: request.systemDefaultInput, operation: "Selecting the recording input")
        for _ in 0..<4 {
            var buffer: AudioQueueBufferRef?
            try AudioCaptureConfiguration.check(AudioQueueAllocateBuffer(queue, format.mBytesPerFrame * UInt32(max(128, min(4096, rate * 0.01))), &buffer),
                                                operation: "Preparing a recording buffer")
            guard let buffer else { throw AudioCaptureError.message("A recording buffer could not be allocated.") }
            try AudioCaptureConfiguration.check(AudioQueueEnqueueBuffer(queue, buffer, 0, nil), operation: "Queuing a recording buffer")
        }
        try AudioCaptureConfiguration.check(AudioQueueStart(queue, nil), operation: "Starting the recording input")
        lock.lock(); inputReadyAfter = ProcessInfo.processInfo.systemUptime + (outputIsBluetooth ? 0.5 : 0); lock.unlock()
        publish(running: true, writer: writer)
    }

    func playCue(start: Bool) throws {
        guard let request else { throw AudioCaptureError.message("The recording output is not prepared.") }
        if start {
            lock.lock(); readyAfterDelivery = writer?.deliveryCount ?? 0; lock.unlock()
        }
        let buffer = try RecordingCuePlayer.buffer(start: start)
        if outputQueue == nil {
            var format = try AudioCaptureConfiguration.format(sampleRate: 48000, channels: 1, selectedChannel: 0)
            var queue: AudioQueueRef?
            let completion = Unmanaged.passRetained(RecordingCueCompletion())
            let status = AudioQueueNewOutput(&format, { context, _, _ in
                guard let context else { return }
                Unmanaged<RecordingCueCompletion>.fromOpaque(context).takeUnretainedValue().bufferConsumed()
            }, completion.toOpaque(), nil, nil, 0, &queue)
            if status != noErr || queue == nil { completion.release() }
            else {
                cueContext = completion
                lock.lock(); cueSnapshot = completion.takeUnretainedValue(); lock.unlock()
            }
            try AudioCaptureConfiguration.check(status, operation: "Creating the recording cue output")
            guard let queue else { throw AudioCaptureError.message("Core Audio did not create a recording cue output.") }
            outputQueue = queue
            try AudioCaptureConfiguration.selectDevice(queue, uid: request.outputUID,
                systemDefault: request.systemDefaultOutput, operation: "Selecting the recording cue output")
        }
        guard let queue = outputQueue else { return }
        var output: AudioQueueBufferRef?
        let bytes = buffer.frameLength * UInt32(MemoryLayout<Float>.size)
        try AudioCaptureConfiguration.check(AudioQueueAllocateBuffer(queue, bytes, &output), operation: "Preparing the recording cue")
        guard let output else { throw AudioCaptureError.message("The recording cue buffer could not be allocated.") }
        // The output queue remains alive for the whole take, including both cues.
        defer { if AudioQueueStop(queue, true) == noErr { AudioQueueFreeBuffer(queue, output) } }
        output.pointee.mAudioData.copyMemory(from: buffer.floatChannelData![0], byteCount: Int(bytes))
        output.pointee.mAudioDataByteSize = bytes
        guard let completion = cueContext?.takeUnretainedValue() else {
            throw AudioCaptureError.message("The recording cue output is unavailable.")
        }
        if !start { completion.reset() }
        else {
            lock.lock(); let stopped = stopRequested; lock.unlock()
            if stopped { completion.cancel() }
        }
        try completion.play(start: {
            try AudioCaptureConfiguration.check(AudioQueueEnqueueBuffer(queue, output, 0, nil), operation: "Queuing the recording cue")
            try AudioCaptureConfiguration.check(AudioQueueStart(queue, nil), operation: "Starting the recording cue")
        }, drain: {
            try AudioCaptureConfiguration.check(AudioQueueStop(queue, false), operation: "Finishing the recording cue")
        }, isRunning: {
            var active: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            try AudioCaptureConfiguration.check(AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &active, &size),
                                                operation: "Checking the recording cue")
            return active != 0
        })
    }

    func begin() throws {
        if let error = progress().1 { throw AudioCaptureError.message(error) }
        guard isReady else { throw AudioCaptureError.message("The input stopped delivering audio before recording could begin.") }
        recording = true; writer?.begin()
    }
    func finish(playCue: Bool = false) -> AudioCaptureResult {
        stopAccepting()
        // Drain disk writes independently; neither the stop cue nor microphone release waits for storage.
        let finalized = DispatchGroup()
        if let writer {
            let url = candidateURL
            finalized.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let result = writer.finish()
                let saved = AudioCaptureResult(url: result.0.frames > 0 ? url : nil, summary: result.0, error: result.1)
                lock.lock(); completedRecording = saved; lock.unlock()
                finalized.leave()
            }
        }
        var finishingError: String?
        if recording && playCue {
            do { try self.playCue(start: false) }
            catch { finishingError = error.localizedDescription }
        }
        recording = false
        // Disposal synchronizes callbacks before releasing their writer context. All of this stays on the worker.
        if let inputQueue {
            AudioQueueStop(inputQueue, true)
            let status = AudioQueueDispose(inputQueue, true)
            if status == noErr {
                self.inputQueue = nil; inputContext?.release(); inputContext = nil
            } else {
                try? AudioCaptureConfiguration.check(status, operation: "Closing the recording input")
            }
        }
        if let outputQueue {
            AudioQueueStop(outputQueue, true)
            let status = AudioQueueDispose(outputQueue, true)
            if status == noErr {
                self.outputQueue = nil
                lock.lock(); cueSnapshot = nil; lock.unlock()
                cueContext?.release(); cueContext = nil
            }
            else { try? AudioCaptureConfiguration.check(status, operation: "Closing the recording cue output") }
        }
        publish(running: false, writer: nil)
        finalized.wait()
        lock.lock(); var saved = completedRecording; lock.unlock()
        saved.error = saved.error ?? finishingError
        writer = nil; request = nil
        let url = candidateURL; candidateURL = nil
        if saved.url == nil, let url { try? FileManager.default.removeItem(at: url) }
        return saved
    }


}

@MainActor
final class AudioCaptureSession: ObservableObject {
    enum State: Equatable { case idle, preparing, recording, finishing }
    private let soundCaptureID = UUID()
    @Published private(set) var state = State.idle {
        didSet { InterfaceSounds.shared.capture(soundCaptureID, active: state != .idle) }
    }
    @Published private(set) var summary: AudioRecordingSummary?
    @Published private(set) var testURL: URL?
    @Published private(set) var isPlaying = false
    @Published var message: ApplicationMessageDescriptor?
    private static var quietPreparations: Set<UUID> = []
    static var suppressesAnnouncements: Bool {
        !quietPreparations.isEmpty || activeSession?.isBusy == true
    }
    static func beginQuietPreparation(_ id: UUID) {
        quietPreparations.insert(id)
        InterfaceSounds.shared.capture(id, active: true)
    }
    static func endQuietPreparation(_ id: UUID) {
        quietPreparations.remove(id)
        InterfaceSounds.shared.capture(id, active: false)
    }
    private var pendingFailure: String?
    private static weak var activeSession: AudioCaptureSession?
    @Published private(set) var isPreparingInput = false
    @Published private(set) var isInputPrepared = false
    private var preparesBeforeRecord = false
    private var waitingForInputOwner = false
    private var finishingTake = false
    private var requestProvider: (() -> AudioCaptureRequest?)?
    private var preparedRequest: AudioCaptureRequest?
    private var preparationMonitor: Timer?
    var canStartRecording: Bool { !closed && !isBusy && (!preparesBeforeRecord || isInputPrepared) }
    var isBusy: Bool { state != .idle || isPreparingInput }
    var isRecordingRequested: Bool { state == .preparing || state == .recording }
    var hasPendingTake: Bool { isRecordingRequested || finishingTake || testURL != nil }
    var maximumDuration: Double? = 60
    private let routes: AudioOutputManager
    private let backend: any AudioCaptureBackend
    private let playCue: (Bool, AudioDeviceID) async throws -> Void
    private let preparationDelay: Duration
    private let player = AVPlayer()
    private var inputUID: String?
    private var outputUID: String?
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var rateObservation: AnyCancellable?
    private var routeObservation: AnyCancellable?
    private var sessionID = UUID()
    private var closed = false
    private var lastFrameCount: Int64 = 0
    private var lastBufferTime = Date()

    init(
        routes: AudioOutputManager? = nil,
        backend: (any AudioCaptureBackend)? = nil,
        preparationDelay: Duration = .milliseconds(700),
        playCue: ((Bool, AudioDeviceID) async throws -> Void)? = nil
    ) {
        let routes = routes ?? AudioOutputManager.shared
        self.routes = routes
        self.backend = backend ?? MicrophoneCaptureBackend()
        self.preparationDelay = preparationDelay
        let captureBackend = self.backend
        self.playCue = playCue ?? { start, _ in if start { try await captureBackend.playStartCue() } }
        routes.register(player)
        rateObservation = player.publisher(for: \.rate).receive(on: RunLoop.main).sink { [weak self] in self?.isPlaying = $0 != 0 }
        routeObservation = routes.$revision.sink { [weak self] _ in
            guard let self, self.state == .recording else { return }
            if self.routes.resolvedDevice?.id != self.outputUID || !self.routes.devices.contains(where: { $0.id == self.inputUID }) {
                self.interrupted("The selected microphone or playback output is no longer available. Any captured audio is available for playback.")
            }
        }
        self.backend.configurationChanged = { [weak self] in
            guard let self, self.state == .recording, !self.backend.isReady else { return }
            self.interrupted("Recording stopped because the microphone stopped delivering audio. Any captured audio is available for playback.")
        }
    }

    func setRecording(_ enabled: Bool, input: AudioInputManager) {
        if enabled { record(input: input) }
        else if isRecordingRequested { stop() }
    }

    private func request(input: AudioInputManager) -> AudioCaptureRequest? {
        guard input.permission == .authorized else { return nil }
        let device = input.resolvedDevice
        let output = routes.resolvedDevice
        return AudioCaptureRequest(inputDeviceID: device?.deviceID ?? 0, inputUID: device?.id ?? input.selectedUID,
            outputDeviceID: output?.deviceID ?? 0, outputUID: output?.id ?? routes.selectedUID,
            channel: input.channel, bitDepth: input.bitDepth, systemDefaultInput: input.selectedUID.isEmpty,
            systemDefaultOutput: routes.selectedUID.isEmpty)
    }

    func prepareInput(input: AudioInputManager) {
        guard !closed, !preparesBeforeRecord else { return }
        routes.refresh()
        input.refresh()
        prepareInput { [weak self, weak input] in
            guard let self, let input else { return nil }
            return self.request(input: input)
        }
    }

    /// Authoring windows prepare the device before Record can retain any samples.
    /// The provider also lets device changes be handled while no take is running.
    func prepareInput(requestProvider: @escaping () -> AudioCaptureRequest?) {
        guard !closed, !preparesBeforeRecord else { return }
        preparesBeforeRecord = true
        self.requestProvider = requestProvider
        preparationMonitor = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkPreparedInput() }
        }
        startInputPreparation()
    }

    private func startInputPreparation() {
        guard !closed, preparesBeforeRecord, !isBusy, !isInputPrepared else { return }
        guard Self.activeSession == nil || Self.activeSession === self else {
            if !waitingForInputOwner { fail("Close the other recording window before preparing this microphone.") }
            waitingForInputOwner = true
            return
        }
        waitingForInputOwner = false
        guard let request = requestProvider?() else {
            preparedRequest = nil
            fail("Allow microphone access in Settings before recording.")
            return
        }
        Self.activeSession = self
        preparedRequest = request
        message = nil
        pendingFailure = nil
        isPreparingInput = true
        sessionID = UUID()
        let id = sessionID
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await self.backend.prepare(request)
                try await self.backend.settle()
                try await Task.sleep(for: self.preparationDelay)
                try await self.waitForInput(sessionID: id)
                try Task.checkCancellation()
                guard self.sessionID == id, !self.closed else { return }
                // A changed selection must settle before Record is enabled.
                guard self.requestProvider?() == request else {
                    self.stop(playCue: false)
                    return
                }
                let actual = self.backend.resolvedRoutes
                self.inputUID = actual?.input ?? request.inputUID
                self.outputUID = actual?.output ?? request.outputUID
                self.isPreparingInput = false
                self.isInputPrepared = true
                self.task = nil
            } catch is CancellationError {
                // Stop/close owns serialized device cleanup.
            } catch {
                guard self.sessionID == id else { return }
                self.stop(playCue: false)
                self.fail(error.localizedDescription)
            }
        }
    }

    private func checkPreparedInput() {
        guard !closed, preparesBeforeRecord, state != .finishing else { return }
        if waitingForInputOwner {
            if Self.activeSession == nil { startInputPreparation() }
            return
        }
        if requestProvider?() != preparedRequest {
            if state == .recording || state == .preparing {
                interrupted("The selected audio device changed. Record another take after preparation finishes.")
            } else if isInputPrepared || isPreparingInput {
                stop(playCue: false)
            } else {
                startInputPreparation()
            }
        } else if isInputPrepared, !backend.isReady || backend.progress().1 != nil {
            stop(playCue: false)
        }
    }

    func record(input: AudioInputManager) {
        if !preparesBeforeRecord { closed = false }
        guard !closed, !isRecordingRequested else { return }
        // Prepared authoring must not refresh or reopen hardware at the Record boundary.
        if !preparesBeforeRecord { routes.refresh(); input.refresh() }
        guard let request = request(input: input) else { fail("Allow microphone access before recording."); return }
        record(request: request)
    }

    func record(request: AudioCaptureRequest) {
        if !preparesBeforeRecord { closed = false }
        guard !closed, !isRecordingRequested, !isPreparingInput else { return }
        if preparesBeforeRecord {
            guard isInputPrepared, preparedRequest == request else {
                checkPreparedInput()
                return
            }
        }
        guard Self.activeSession == nil || Self.activeSession === self else {
            fail("Close the other recording window before starting a new take.")
            return
        }
        guard state != .finishing else { return }
        Self.activeSession = self
        player.pause()
        player.replaceCurrentItem(with: nil)
        message = nil
        pendingFailure = nil
        sessionID = UUID()
        let id = sessionID
        inputUID = request.inputUID
        outputUID = request.outputUID
        let alreadyPrepared = isInputPrepared
        isInputPrepared = false
        state = .preparing
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                guard self.sessionID == id else { return }
                if !alreadyPrepared {
                    try await self.backend.prepare(request)
                    try await self.backend.settle()
                    try await Task.sleep(for: self.preparationDelay)
                    try await self.waitForInput(sessionID: id)
                }
                try await self.playCue(true, request.outputDeviceID)
                try Task.checkCancellation()
                guard self.sessionID == id else { return }
                self.lastFrameCount = 0; self.lastBufferTime = Date()
                try await self.backend.begin()
                try Task.checkCancellation()
                guard self.sessionID == id else { return }
                if let actual = self.backend.resolvedRoutes {
                    self.inputUID = actual.input; self.outputUID = actual.output
                }
                self.state = .recording
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.checkCapture() }
                }
            } catch is CancellationError {
                // The stop/close path owns cleanup.
            } catch {
                guard self.sessionID == id else { return }
                self.stop(playCue: false)
                self.fail(error.localizedDescription)
            }
        }
    }

    private func waitForInput(sessionID id: UUID) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !backend.isReady {
            try Task.checkCancellation()
            guard sessionID == id else { throw CancellationError() }
            guard ContinuousClock.now < deadline else {
                throw AudioCaptureError.message(backend.preparationIssue ?? "No audio arrived from the selected input. Check the input device and try again.")
            }
            try await backend.settle()
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func checkCapture() {
        guard state == .recording else { return }
        let (summary, error) = backend.progress()
        if summary.frames != lastFrameCount { lastFrameCount = summary.frames; lastBufferTime = Date() }
        if let error { interrupted(error) }
        else if Date().timeIntervalSince(lastBufferTime) > 5 { interrupted("The microphone stopped providing audio. Check the input device and record another take.") }
        else if let maximumDuration, summary.duration >= maximumDuration { stop() }
    }

    func stop(playCue: Bool = true) {
        guard isBusy || isInputPrepared, state != .finishing else { player.pause(); return }
        sessionID = UUID()
        let id = sessionID
        task?.cancel(); task = nil
        timer?.invalidate(); timer = nil
        finishingTake = isRecordingRequested
        backend.stopAccepting()
        isInputPrepared = false
        isPreparingInput = false
        state = .finishing
        task = Task { [self] in
            let result = await backend.finish(playCue: playCue)
            guard sessionID == id else { return }
            if let url = result.url {
                if closed { try? FileManager.default.removeItem(at: url) }
                else { deleteTest(); testURL = url; summary = result.summary }
            }
            state = .idle
            finishingTake = false
            if Self.activeSession === self { Self.activeSession = nil }
            let failure = pendingFailure ?? result.error
            pendingFailure = nil
            if let failure, !closed { fail(failure) }
            task = nil
            if failure == nil, !closed { startInputPreparation() }
        }
    }

    func setTestPlayback(_ enabled: Bool) {
        if enabled { playTest() }
        else { player.pause() }
    }

    func playTest() {
        guard !isBusy, let testURL else { return }
        guard routes.isAvailable else { fail("Choose an available audio playback output."); return }
        player.replaceCurrentItem(with: AVPlayerItem(url: testURL))
        player.play()
    }

    func deleteTest() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let testURL { try? FileManager.default.removeItem(at: testURL) }
        testURL = nil
        summary = nil
    }

    func close() {
        closed = true
        preparationMonitor?.invalidate(); preparationMonitor = nil
        requestProvider = nil
        stop(playCue: false)
        deleteTest()
    }
    private func interrupted(_ detail: String) { stop(playCue: false); fail(detail) }
    private func fail(_ detail: String) {
        if isBusy { pendingFailure = detail; return }
        message = ApplicationMessageDescriptor(title: "Audio Recording", message: detail, initialFocus: .message)
    }
}
