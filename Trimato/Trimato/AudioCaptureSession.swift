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

    func begin() { lock.lock(); accepting = true; lock.unlock() }

    func receive(_ source: AVAudioPCMBuffer) {
        lock.lock()
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

@MainActor
final class AudioCaptureSession: ObservableObject {
    enum State: Equatable { case idle, preparing, recording, finishing }
    @Published private(set) var state = State.idle
    @Published private(set) var summary: AudioRecordingSummary?
    @Published private(set) var testURL: URL?
    @Published private(set) var isPlaying = false
    @Published var message: ApplicationMessageDescriptor?
    static var suppressesAnnouncements = false
    var isBusy: Bool { state != .idle }
    private let routes: AudioOutputManager
    private let cue = RecordingCuePlayer()
    private let player = AVPlayer()
    private var engine: AVAudioEngine?
    private var writer: AudioCaptureWriter?
    private var candidateURL: URL?
    private var inputUID: String?
    private var outputUID: String?
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var rateObservation: AnyCancellable?
    private var routeObservation: AnyCancellable?
    private var configurationObserver: NSObjectProtocol?
    private var sessionID = UUID()
    private var lastFrameCount: Int64 = 0
    private var lastBufferTime = Date()

    init(routes: AudioOutputManager? = nil) {
        let routes = routes ?? AudioOutputManager.shared
        self.routes = routes
        routes.register(player)
        rateObservation = player.publisher(for: \.rate).receive(on: RunLoop.main).sink { [weak self] in self?.isPlaying = $0 != 0 }
        routeObservation = routes.$revision.sink { [weak self] _ in
            guard let self, self.isBusy else { return }
            if self.routes.resolvedDevice?.id != self.outputUID || !self.routes.devices.contains(where: { $0.id == self.inputUID }) {
                self.interrupted("An audio device became unavailable or the output route changed. Review the captured portion before recording again.")
            }
        }
    }

    func record(input: AudioInputManager) {
        guard !isBusy else { return }
        guard input.permission == .authorized else { fail("Allow microphone access before recording a test."); return }
        guard let device = input.resolvedDevice, input.channel < device.inputChannels else { fail("Choose an available microphone and input channel."); return }
        guard let output = routes.resolvedDevice else { fail("Choose an available audio playback output."); return }
        player.pause()
        sessionID = UUID()
        let id = sessionID
        inputUID = device.id
        outputUID = output.id
        state = .preparing
        Self.suppressesAnnouncements = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try self.prepare(deviceID: device.deviceID, channel: input.channel, bitDepth: input.bitDepth)
                // Let activation speech settle before the nonverbal cue. No focus request or announcement.
                try await Task.sleep(for: .milliseconds(700))
                try await self.cue.play(start: true, deviceID: output.deviceID)
                try await Task.sleep(for: .milliseconds(300))
                try Task.checkCancellation()
                guard self.sessionID == id else { return }
                self.lastFrameCount = 0
                self.lastBufferTime = Date()
                self.writer?.begin()
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

    private func prepare(deviceID: AudioDeviceID, channel: Int, bitDepth: Int) throws {
        let engine = AVAudioEngine()
        self.engine = engine
        let node = engine.inputNode
        guard let unit = node.audioUnit else { throw AudioCaptureError.message("The microphone could not be opened.") }
        var deviceID = deviceID
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            throw AudioCaptureError.message("The selected microphone could not be opened.")
        }
        let format = node.outputFormat(forBus: 0)
        guard format.channelCount > channel, format.sampleRate > 0 else { throw AudioCaptureError.message("The selected input channel is unavailable.") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Trimato-Recording-Test-\(UUID().uuidString).wav")
        candidateURL = url
        let writer = try AudioCaptureWriter(url: url, sampleRate: format.sampleRate, channel: channel, bitDepth: bitDepth)
        self.writer = writer
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in writer.receive(buffer) }
        try engine.start()
        let id = sessionID
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isBusy, self.sessionID == id else { return }
                self.interrupted("The microphone configuration changed. Review the captured portion before recording again.")
            }
        }
    }

    private func checkCapture() {
        guard state == .recording, let writer else { return }
        let (summary, error) = writer.snapshot()
        if summary.frames != lastFrameCount { lastFrameCount = summary.frames; lastBufferTime = Date() }
        if let error { interrupted(error) }
        else if Date().timeIntervalSince(lastBufferTime) > 5 { interrupted("The microphone stopped providing audio. Check the input device and record another test.") }
        else if summary.duration >= 60 { stop() }
    }

    func stop(playCue: Bool = true) {
        guard isBusy else { player.pause(); return }
        let wasRecording = state == .recording
        sessionID = UUID()
        task?.cancel()
        task = nil
        cue.stop()
        timer?.invalidate(); timer = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        let result = writer?.finish()
        engine?.stop()
        if writer != nil { engine?.inputNode.removeTap(onBus: 0) }
        engine = nil
        writer = nil
        if let url = candidateURL {
            if let result, result.0.frames > 0 {
                deleteTest()
                testURL = url
                summary = result.0
            } else { try? FileManager.default.removeItem(at: url) }
        }
        candidateURL = nil
        state = .idle
        Self.suppressesAnnouncements = false
        if playCue, wasRecording, let output = routes.resolvedDevice {
            state = .finishing
            task = Task { [weak self] in
                guard let self else { return }
                do { try await self.cue.play(start: false, deviceID: output.deviceID) }
                catch is CancellationError { return }
                catch { self.fail(error.localizedDescription) }
                self.state = .idle
            }
        }
        if let error = result?.1 { fail(error) }
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
