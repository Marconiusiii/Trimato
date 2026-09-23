import AVFoundation
import AudioToolbox
import Combine

/// A bounded PCM preview. The reader works away from the main actor; video stays paused.
nonisolated enum FrameAudioSamples {
    static let sampleRate = 48_000.0
    static let channels = 2

    private static let decoder = FrameAudioDecoder()

    static func read(asset: AVAsset, mix: AVAudioMix?, at time: CMTime) async throws -> [Float] {
        try await decoder.read(asset: asset, mix: mix, at: time)
    }
}

/// Only one blocking reader runs at a time, even during rapid replacement requests.
private actor FrameAudioDecoder {
    func read(asset: AVAsset, mix: AVAudioMix?, at time: CMTime) async throws -> [Float] {
        try Task.checkCancellation()
        let sampleRate = FrameAudioSamples.sampleRate
        let channels = FrameAudioSamples.channels
        guard time.isNumeric, time.seconds >= 0 else { return [] }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return [] }
        let duration = try await asset.load(.duration)
        guard duration.isNumeric else { return [] }
        let length = min(0.2, max(0, duration.seconds - time.seconds))
        guard length > 0 else { return [] }
        try Task.checkCancellation()
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: time, duration: CMTime(seconds: length, preferredTimescale: 48_000))
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels, AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false
        ])
        output.audioMix = mix
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw CocoaError(.fileReadUnknown) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        defer { reader.cancelReading() }
        let frameCount = Int((length * sampleRate).rounded())
        var samples = [Float](repeating: 0, count: frameCount * channels)
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let data = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let offset = Int(((CMSampleBufferGetPresentationTimeStamp(buffer).seconds - time.seconds) * sampleRate).rounded())
            let firstSourceFrame = max(0, -offset)
            let firstDestinationFrame = max(0, offset)
            let count = min(CMSampleBufferGetNumSamples(buffer) - firstSourceFrame, frameCount - firstDestinationFrame)
            guard count > 0 else { continue }
            let status = samples.withUnsafeMutableBytes { destination in
                CMBlockBufferCopyDataBytes(data, atOffset: firstSourceFrame * channels * 4,
                    dataLength: count * channels * 4,
                    destination: destination.baseAddress!.advanced(by: firstDestinationFrame * channels * 4))
            }
            guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        }
        guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        return samples
    }
}

@MainActor
final class FrameAudioPreview {
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var deviceID: AudioDeviceID?
    private var idleTask: Task<Void, Never>?
    private var routeObservation: AnyCancellable?
    private var configurationObservation: NSObjectProtocol?
    private(set) var isPlaying = false

    init() {
        routeObservation = AudioOutputManager.shared.$revision.dropFirst().sink { [weak self] _ in
            guard let self, self.deviceID != AudioOutputManager.shared.resolvedDevice?.deviceID else { return }
            self.shutdown()
        }
    }

    deinit {
        idleTask?.cancel()
        if let configurationObservation { NotificationCenter.default.removeObserver(configurationObservation) }
        engine?.stop()
    }

    func play(_ samples: [Float], volume: Float, muted: Bool) throws {
        stop()
        guard !samples.isEmpty, !muted, let device = AudioOutputManager.shared.resolvedDevice else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: FrameAudioSamples.sampleRate, channels: 2)!
        if engine == nil || deviceID != device.deviceID {
            shutdown()
            let engine = AVAudioEngine()
            guard let unit = engine.outputNode.audioUnit else { throw CocoaError(.featureUnsupported) }
            var id = device.deviceID
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            engine.prepare()
            self.engine = engine; self.node = node; deviceID = device.deviceID
            configurationObservation = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.shutdown() } }
        }
        guard let engine, let node,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count / 2)),
              let channels = buffer.floatChannelData else { throw CocoaError(.featureUnsupported) }
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            channels[0][frame] = samples[frame * 2]
            channels[1][frame] = samples[frame * 2 + 1]
        }
        node.volume = volume
        if !engine.isRunning { try engine.start() }
        node.scheduleBuffer(buffer)
        node.play()
        isPlaying = true
        // Let the buffer finish naturally. Keep the engine ready for adjacent taps,
        // then release the output when jogging stops.
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            self?.shutdown()
        }
    }

    func stop() {
        node?.stop()
        isPlaying = false
    }

    private func shutdown() {
        idleTask?.cancel(); idleTask = nil
        if let configurationObservation { NotificationCenter.default.removeObserver(configurationObservation) }
        configurationObservation = nil
        node?.stop(); engine?.stop()
        node = nil; engine = nil; deviceID = nil; isPlaying = false
    }
}
