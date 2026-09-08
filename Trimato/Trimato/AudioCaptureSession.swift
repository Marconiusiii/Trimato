import AVFoundation
import AudioToolbox
import Combine

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

    deinit { timer?.cancel(); TCaptureDestroy(ring) }
    var hasReceivedAudio: Bool { TCaptureReceived(ring) != 0 }
    var deliveryCount: UInt64 { TCaptureDeliveries(ring) }
    func begin() { TCaptureBegin(ring) }
    func stopAccepting() { TCaptureStop(ring) }

    func receive(_ source: AVAudioPCMBuffer) {
        let valid = source.format.sampleRate == sampleRate && channel < Int(source.format.channelCount)
        let samples = valid ? (source.format.isInterleaved ? source.floatChannelData?[0].advanced(by: channel) : source.floatChannelData?[channel]) : nil
        TCapturePush(ring, samples, source.frameLength, UInt32(source.stride), samples == nil ? 0 : 1)
    }

    // Audio Queue delivers interleaved float PCM, converted by Core Audio from the device format.
    func receive(_ source: AudioQueueBufferRef, queue: AudioQueueRef) {
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
        while TCaptureActive(ring) != 0 { Thread.sleep(forTimeInterval: 0.001) }
        queue.sync { timer?.cancel(); timer = nil; drain(); file = nil }
        return snapshot()
    }
}

nonisolated struct AudioCaptureRequest: Sendable {
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
    func waitForPlaybackOutput() async throws
    func finish(playCue: Bool) async -> AudioCaptureResult
}

extension AudioCaptureBackend {
    var resolvedRoutes: (input: String, output: String)? { nil }
    var preparationIssue: String? { nil }
    func stopAccepting() { }
    func playStartCue() async throws { }
    func waitForPlaybackOutput() async throws { }
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
    func waitForPlaybackOutput() async throws {
        try await worker.run { [device] in try device.waitForPlaybackOutput() }
    }
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
    private var outputBaseline: RecordingOutputSnapshot?
    private var recoveryRequest: AudioCaptureRequest?
    private var outputNeedsRecovery = false
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
        outputBaseline = nil
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
        if outputBaseline == nil {
            outputBaseline = RecordingOutputSnapshot(uid: output.id, sampleRate: AudioHardware.sampleRate(output.deviceID), channels: output.outputChannels)
            var property = AudioHardware.address(kAudioDevicePropertyTransportType)
            var transport: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(output.deviceID, &property, 0, nil, &size, &transport)
            outputIsBluetooth = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(transport)
        }
        recoveryRequest = request
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
        var queue: AudioQueueRef?
        let context = Unmanaged.passRetained(writer)
        let created = AudioQueueNewInput(&format, { context, queue, buffer, _, _, _ in
            guard let context else { return }
            Unmanaged<AudioCaptureWriter>.fromOpaque(context).takeUnretainedValue().receive(buffer, queue: queue)
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
        outputNeedsRecovery = true
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
        do { try waitForPlaybackOutput() }
        catch { finishingError = finishingError ?? error.localizedDescription }
        finalized.wait()
        lock.lock(); var saved = completedRecording; lock.unlock()
        saved.error = saved.error ?? finishingError
        writer = nil; request = nil
        let url = candidateURL; candidateURL = nil
        if saved.url == nil, let url { try? FileManager.default.removeItem(at: url) }
        return saved
    }

    func waitForPlaybackOutput() throws {
        guard outputNeedsRecovery else { return }
        guard inputQueue == nil, outputQueue == nil else {
            throw AudioCaptureError.message("The recording device is still closing. Playback will be available after it closes.")
        }
        guard let baseline = outputBaseline, let request = recoveryRequest else { return }
        var recovery = RecordingOutputRecovery(baseline: baseline, settlingTime: outputIsBluetooth ? 0.5 : 0.1)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let devices = AudioHardware.devices()
            let defaultID = AudioHardware.defaultDevice(input: false)
            let device = devices.first { request.systemDefaultOutput ? $0.deviceID == defaultID : $0.id == request.outputUID }
            let snapshot = device.map { RecordingOutputSnapshot(uid: $0.id, sampleRate: AudioHardware.sampleRate($0.deviceID), channels: $0.outputChannels) }
            if recovery.observe(snapshot, at: ProcessInfo.processInfo.systemUptime) {
                outputNeedsRecovery = false; return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw AudioCaptureError.message("The playback output has not recovered after recording. Wait for the headset to reconnect, then try playback again.")
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
    static var suppressesAnnouncements = false
    private static weak var activeSession: AudioCaptureSession?
    var isBusy: Bool { state != .idle }
    var isRecordingRequested: Bool { state == .preparing || state == .recording }
    var maximumDuration: Double? = 60
    private let routes: AudioOutputManager
    private let backend: any AudioCaptureBackend
    private let playCue: (Bool, AudioDeviceID) async throws -> Void
    private let preparationDelay: Duration
    private let player = AVPlayer()
    private var inputUID: String?
    private var outputUID: String?
    private var task: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
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

    func record(input: AudioInputManager) {
        closed = false
        guard !isRecordingRequested else { return }
        routes.refresh()
        input.refresh()
        guard input.permission == .authorized else { fail("Allow microphone access before recording."); return }
        let device = input.resolvedDevice
        let output = routes.resolvedDevice
        record(request: AudioCaptureRequest(inputDeviceID: device?.deviceID ?? 0, inputUID: device?.id ?? input.selectedUID,
            outputDeviceID: output?.deviceID ?? 0, outputUID: output?.id ?? routes.selectedUID,
            channel: input.channel, bitDepth: input.bitDepth, systemDefaultInput: input.selectedUID.isEmpty,
            systemDefaultOutput: routes.selectedUID.isEmpty))
    }

    func record(request: AudioCaptureRequest) {
        closed = false
        guard !isRecordingRequested else { return }
        guard Self.activeSession == nil || Self.activeSession === self else {
            fail("Stop the other recording before starting a new take.")
            return
        }
        guard state != .finishing else { return }
        Self.activeSession = self
        player.pause()
        player.replaceCurrentItem(with: nil)
        message = nil
        sessionID = UUID()
        let id = sessionID
        inputUID = request.inputUID
        outputUID = request.outputUID
        state = .preparing
        Self.suppressesAnnouncements = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                guard self.sessionID == id else { return }
                try await self.backend.prepare(request)
                try await self.backend.settle()
                // No focus request or start announcement. Input configuration settles and
                // actual input buffers arrive before the cue and before samples are retained.
                try await Task.sleep(for: self.preparationDelay)
                try await self.waitForInput(sessionID: id)
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
        guard isBusy, state != .finishing else { player.pause(); return }
        sessionID = UUID()
        let id = sessionID
        task?.cancel(); task = nil
        timer?.invalidate(); timer = nil
        backend.stopAccepting()
        state = .finishing
        Self.suppressesAnnouncements = false
        task = Task { [self] in
            let result = await backend.finish(playCue: playCue)
            guard sessionID == id else { return }
            if let url = result.url {
                if closed { try? FileManager.default.removeItem(at: url) }
                else { deleteTest(); testURL = url; summary = result.summary }
            }
            state = .idle
            if Self.activeSession === self { Self.activeSession = nil }
            if let error = result.error, !closed { fail(error) }
            task = nil
        }
    }

    func setTestPlayback(_ enabled: Bool) {
        if enabled { playTest() }
        else { playbackTask?.cancel(); playbackTask = nil; player.pause() }
    }

    func playTest() {
        guard !isBusy, let testURL else { return }
        guard routes.isAvailable else { fail("Choose an available audio playback output."); return }
        playbackTask?.cancel()
        playbackTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await preparePlayback()
                guard !closed, !isBusy, self.testURL == testURL else { return }
                player.replaceCurrentItem(with: AVPlayerItem(url: testURL))
                player.play()
            } catch is CancellationError { }
            catch { fail(error.localizedDescription) }
        }
    }

    func preparePlayback() async throws {
        try await backend.waitForPlaybackOutput()
        try Task.checkCancellation()
    }

    func deleteTest() {
        playbackTask?.cancel(); playbackTask = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let testURL { try? FileManager.default.removeItem(at: testURL) }
        testURL = nil
        summary = nil
    }

    func close() { closed = true; stop(playCue: false); deleteTest() }
    private func interrupted(_ detail: String) { stop(playCue: false); fail(detail) }
    private func fail(_ detail: String) { message = ApplicationMessageDescriptor(title: "Audio Recording", message: detail, initialFocus: .message) }
}
