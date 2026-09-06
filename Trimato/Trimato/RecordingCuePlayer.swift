import AVFoundation
import AudioToolbox

@MainActor
final class RecordingCuePlayer {
    private var generation = UUID()
    private var timeout: Task<Void, Never>?
    private var engine: AVAudioEngine?
    private var completion: CheckedContinuation<Void, Error>?

    func play(start: Bool, deviceID: AudioDeviceID) async throws {
        stop()
        let id = generation
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        guard let unit = engine.outputNode.audioUnit else { throw AudioCaptureError.message("The playback output could not be opened.") }
        var device = deviceID
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            throw AudioCaptureError.message("The recording cue could not use the selected output.")
        }
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
        engine.connect(node, to: engine.mainMixerNode, format: format)
        self.engine = engine
        try engine.start()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == id else { return }
                        self.finish()
                    }
                }
                timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    guard let self, self.generation == id else { return }
                    let pending = self.completion
                    self.completion = nil
                    self.stop()
                    pending?.resume(throwing: AudioCaptureError.message("The recording cue could not finish on the selected output. Check the device and try again."))
                }
                node.play()
                if Task.isCancelled { stop() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == id else { return }
                self.stop()
            }
        }
    }

    private func finish() {
        timeout?.cancel(); timeout = nil
        generation = UUID()
        engine?.stop()
        engine = nil
        let pending = completion
        completion = nil
        pending?.resume()
    }

    func stop() {
        timeout?.cancel(); timeout = nil
        generation = UUID()
        engine?.stop()
        engine = nil
        let pending = completion
        completion = nil
        pending?.resume(throwing: CancellationError())
    }
}
