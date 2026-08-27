import AVFoundation
import Foundation
import Testing
@testable import Trimato

@Suite("Audio waveform")
struct AudioWaveformTests {
    @Test func editedSourceRangesProduceTheEditedWaveform() {
        let waveform = AudioWaveformData(
            samples: Array(0..<10).map(Float.init),
            duration: 10
        )
        let ranges = [
            CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600), duration: CMTime(seconds: 2, preferredTimescale: 600)),
            CMTimeRange(start: CMTime(seconds: 7, preferredTimescale: 600), duration: CMTime(seconds: 2, preferredTimescale: 600)),
        ]

        #expect(waveform.samples(for: ranges, maximumCount: 10) == [1, 2, 7, 8])
    }

    @Test func downsamplingPreservesThePeakInEachBucket() {
        #expect(AudioWaveformData.downsample([0.1, 0.8, 0.3, 0.6], maximumCount: 2) == [0.8, 0.6])
    }

    @Test func nativeAnalyzerCreatesBoundedNormalizedSamples() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
            buffer.frameLength = 48_000
            let channel = try #require(buffer.floatChannelData?[0])
            for index in 0..<48_000 {
                channel[index] = sin(Float(index) * 2 * .pi * 440 / 48_000) * 0.5
            }
            try file.write(from: buffer)
        }

        let waveform = try await AudioWaveformAnalyzer.analyze(
            asset: AVURLAsset(url: url),
            maximumCount: 128
        )

        #expect(waveform.samples.count == 128)
        #expect(waveform.samples.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect((waveform.samples.max() ?? 0) > 0.9)
    }
}
