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
