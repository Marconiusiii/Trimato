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

// Ownership transfers to the writer queue after the tap finishes copying this buffer.
nonisolated private struct CapturedAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

// The tap copies only the chosen channel. File I/O is serialized off the audio callback,
// with a bounded backlog. Stop closes the gate before draining and closing the file.
nonisolated final class AudioCaptureWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.marconius.trimato.recording-writer")
    private var accepting = false
    private var receivedAudio = false
    private var pending = 0
    private var file: AVAudioFile?
    private var summary = AudioRecordingSummary()
    private var failure: String?
    private let channel: Int
    private let format: AVAudioFormat

    init(url: URL, sampleRate: Double, channel: Int, bitDepth: Int) throws {
        guard sampleRate.isFinite, sampleRate > 0, channel >= 0, [16, 24].contains(bitDepth),
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw AudioCaptureError.message("The microphone format is unsupported.")
        }
        self.format = format
        self.channel = channel
        summary.sampleRate = sampleRate
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    var hasReceivedAudio: Bool {
        lock.lock(); defer { lock.unlock() }
        return receivedAudio
    }

    func begin() { lock.lock(); accepting = true; lock.unlock() }

    func receive(_ source: AVAudioPCMBuffer) {
        lock.lock()
        if source.frameLength > 0, source.format.sampleRate == format.sampleRate,
           channel < Int(source.format.channelCount), source.floatChannelData != nil {
            receivedAudio = true
        }
        guard accepting, failure == nil else { lock.unlock(); return }
        guard pending < 32 else {
            failure = "Recording stopped because storage could not keep up. The captured part of the test is available for playback."
            accepting = false
            lock.unlock()
            return
        }
        guard source.format.sampleRate == format.sampleRate,
              channel < Int(source.format.channelCount), let sourceData = source.floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: source.frameLength),
              let destination = copy.floatChannelData?[0] else {
            failure = "The microphone format changed during recording."
            accepting = false
            lock.unlock()
            return
        }
        copy.frameLength = source.frameLength
        for index in 0..<Int(source.frameLength) { destination[index] = sourceData[channel][index * source.stride] }
        pending += 1
        // Enqueue under the gate lock so finish cannot drain before this buffer is queued.
        let packet = CapturedAudioBuffer(buffer: copy)
        queue.async { [self, packet] in
            let copy = packet.buffer
            guard let destination = copy.floatChannelData?[0] else { return }
            do {
                try file?.write(from: copy)
                lock.lock()
                summary.frames += Int64(copy.frameLength)
                for index in 0..<Int(copy.frameLength) {
                    let magnitude = abs(destination[index])
                    summary.peak = max(summary.peak, magnitude)
                    if magnitude >= 1 { summary.clippedSamples += 1 }
                }
                pending -= 1
                lock.unlock()
            } catch {
                lock.lock()
                failure = "The recording could not be written: \(error.localizedDescription)"
                accepting = false
                pending -= 1
                lock.unlock()
            }
        }
        lock.unlock()
    }

    func snapshot() -> (AudioRecordingSummary, String?) {
        lock.lock(); defer { lock.unlock() }
        return (summary, failure)
    }

    func finish() -> (AudioRecordingSummary, String?) {
        lock.lock(); accepting = false; lock.unlock()
        queue.sync { file = nil }
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
}

nonisolated struct AudioCaptureResult {
    var url: URL?
    var summary = AudioRecordingSummary()
    var error: String?
}

@MainActor
protocol AudioCaptureBackend: AnyObject {
    var isReady: Bool { get }
    var configurationChanged: (() -> Void)? { get set }
    func prepare(_ request: AudioCaptureRequest) throws
    func settle() throws
    func begin()
    func progress() -> (AudioRecordingSummary, String?)
    func finish() -> AudioCaptureResult
}

@MainActor
private final class MicrophoneCaptureBackend: AudioCaptureBackend {
    var configurationChanged: (() -> Void)?
    private var engine: AVAudioEngine?
    private var writer: AudioCaptureWriter?
    private var request: AudioCaptureRequest?
    private var candidateURL: URL?
    private var observer: NSObjectProtocol?
    private var hasTap = false
    private var generation = UUID()

    var isReady: Bool { engine?.isRunning == true && writer?.hasReceivedAudio == true }

    func prepare(_ request: AudioCaptureRequest) throws {
        self.request = request
        let engine = AVAudioEngine()
        self.engine = engine
        generation = UUID()
        let id = generation
        // Receive asynchronously, outside the engine's notification callback. Selecting an
        // input can itself reconfigure the engine; preparation will settle that normally.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == id else { return }
                self.configurationChanged?()
            }
        }
        guard let unit = engine.inputNode.audioUnit else { throw AudioCaptureError.message("The microphone could not be opened.") }
        var current = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &current, &size)
        if status != noErr || current != request.inputDeviceID {
            var selected = request.inputDeviceID
            guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &selected, size) == noErr else {
                throw AudioCaptureError.message("The selected microphone could not be opened.")
            }
        }
    }

    func settle() throws {
        guard let engine, let request else { throw AudioCaptureError.message("The microphone is not prepared.") }
        if engine.isRunning, writer != nil { return }
        // A startup configuration change can stop the engine and invalidate its tap format.
        // Re-read the format and rebuild only this unsaved preparation, on the same engine.
        discardWriter()
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard request.channel >= 0, format.channelCount > request.channel, format.sampleRate > 0 else {
            throw AudioCaptureError.message("The selected input channel is unavailable.")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Trimato-Recording-Test-\(UUID().uuidString).wav")
        candidateURL = url
        let writer = try AudioCaptureWriter(url: url, sampleRate: format.sampleRate, channel: request.channel, bitDepth: request.bitDepth)
        self.writer = writer
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in writer.receive(buffer) }
        hasTap = true
        try engine.start()
    }

    func begin() { writer?.begin() }
    func progress() -> (AudioRecordingSummary, String?) { writer?.snapshot() ?? (AudioRecordingSummary(), nil) }

    func finish() -> AudioCaptureResult {
        generation = UUID()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        let result = writer?.finish()
        engine?.stop()
        if hasTap { engine?.inputNode.removeTap(onBus: 0) }
        hasTap = false
        engine = nil
        writer = nil
        request = nil
        let url = candidateURL
        candidateURL = nil
        if let result, result.0.frames > 0 {
            return AudioCaptureResult(url: url, summary: result.0, error: result.1)
        }
        if let url { try? FileManager.default.removeItem(at: url) }
        return AudioCaptureResult(error: result?.1)
    }

    private func discardWriter() {
        _ = writer?.finish()
        if hasTap { engine?.inputNode.removeTap(onBus: 0) }
        hasTap = false
        writer = nil
        if let candidateURL { try? FileManager.default.removeItem(at: candidateURL) }
        candidateURL = nil
    }
}

@MainActor
final class AudioCaptureSession: ObservableObject {
    enum State: Equatable { case idle, preparing, recording, finishing }
    @Published private(set) var state = State.idle
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
    private let cue = RecordingCuePlayer()
    private let playCue: (Bool, AudioDeviceID) async throws -> Void
    private let preparationDelay: Duration
    private let cueSettlingDelay: Duration
    private let player = AVPlayer()
    private var inputUID: String?
    private var outputUID: String?
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var rateObservation: AnyCancellable?
    private var routeObservation: AnyCancellable?
    private var sessionID = UUID()
    private var lastFrameCount: Int64 = 0
    private var lastBufferTime = Date()

    init(
        routes: AudioOutputManager? = nil,
        backend: (any AudioCaptureBackend)? = nil,
        preparationDelay: Duration = .milliseconds(700),
        cueSettlingDelay: Duration = .milliseconds(300),
        playCue: ((Bool, AudioDeviceID) async throws -> Void)? = nil
    ) {
        let routes = routes ?? AudioOutputManager.shared
        self.routes = routes
        self.backend = backend ?? MicrophoneCaptureBackend()
        self.preparationDelay = preparationDelay
        self.cueSettlingDelay = cueSettlingDelay
        self.playCue = playCue ?? { [cue] start, device in try await cue.play(start: start, deviceID: device) }
        routes.register(player)
        rateObservation = player.publisher(for: \.rate).receive(on: RunLoop.main).sink { [weak self] in self?.isPlaying = $0 != 0 }
        routeObservation = routes.$revision.sink { [weak self] _ in
            guard let self, self.isRecordingRequested else { return }
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
        guard !isRecordingRequested else { return }
        guard input.permission == .authorized else { fail("Allow microphone access before recording."); return }
        guard let device = input.resolvedDevice, input.channel >= 0, input.channel < device.inputChannels else { fail("Choose an available microphone and input channel."); return }
        guard let output = routes.resolvedDevice else { fail("Choose an available audio playback output."); return }
        record(request: AudioCaptureRequest(inputDeviceID: device.deviceID, inputUID: device.id, outputDeviceID: output.deviceID, outputUID: output.id, channel: input.channel, bitDepth: input.bitDepth))
    }

    func record(request: AudioCaptureRequest) {
        guard !isRecordingRequested else { return }
        guard Self.activeSession == nil || Self.activeSession === self else {
            fail("Stop the other recording before starting a new take.")
            return
        }
        if state == .finishing { stop(playCue: false) }
        Self.activeSession = self
        player.pause()
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
                try self.backend.prepare(request)
                // No focus request or start announcement. Input configuration settles and
                // actual input buffers arrive before the cue and before samples are retained.
                try await Task.sleep(for: self.preparationDelay)
                for _ in 0..<3 {
                    try await self.waitForInput(sessionID: id)
                    try await self.playCue(true, request.outputDeviceID)
                    try await Task.sleep(for: self.cueSettlingDelay)
                    try Task.checkCancellation()
                    guard self.sessionID == id else { return }
                    // Starting cue playback may also reconfigure a shared audio device.
                    // Settle and replay the cue if needed; this is not a recording failure.
                    guard self.backend.isReady else { continue }
                    self.lastFrameCount = 0
                    self.lastBufferTime = Date()
                    self.backend.begin()
                    self.state = .recording
                    self.timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                        Task { @MainActor [weak self] in self?.checkCapture() }
                    }
                    return
                }
                throw AudioCaptureError.message("The microphone could not stay ready for recording. Check the selected input and output, then try again.")
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
                throw AudioCaptureError.message("No audio arrived from the selected microphone. Check the input device and try again.")
            }
            try backend.settle()
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
        guard isBusy else { player.pause(); return }
        let wasRecording = state == .recording
        sessionID = UUID()
        let id = sessionID
        task?.cancel()
        task = nil
        cue.stop()
        timer?.invalidate(); timer = nil
        let result = backend.finish()
        if let url = result.url {
            deleteTest()
            testURL = url
            summary = result.summary
        }
        state = .idle
        if Self.activeSession === self {
            Self.activeSession = nil
            Self.suppressesAnnouncements = false
        }
        if playCue, wasRecording, let output = routes.resolvedDevice {
            state = .finishing
            task = Task { [weak self] in
                guard let self else { return }
                do { try await self.playCue(false, output.deviceID) }
                catch is CancellationError { return }
                catch { if self.sessionID == id { self.fail(error.localizedDescription) } }
                guard self.sessionID == id else { return }
                self.state = .idle
            }
        }
        if let error = result.error { fail(error) }
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

    func close() { stop(playCue: false); deleteTest() }
    private func interrupted(_ detail: String) { stop(playCue: false); fail(detail) }
    private func fail(_ detail: String) { message = ApplicationMessageDescriptor(title: "Audio Recording", message: detail, initialFocus: .message) }
}
