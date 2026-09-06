import AVFoundation
import Testing
@testable import Trimato

@Suite("Audio capture storage")
struct AudioCaptureSessionTests {
    private func buffer() throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let samples = try #require(buffer.floatChannelData)
        for index in 0..<4 { samples[0][index] = 0.125; samples[1][index] = index == 0 ? 1 : 0.5 }
        return buffer
    }

    @Test func cueAndPostStopSamplesAreExcludedAndSelectedChannelIsSaved() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioCaptureWriter(url: url, sampleRate: 48_000, channel: 1, bitDepth: 24)
        let source = try buffer()
        writer.receive(source)
        writer.begin()
        writer.receive(source)
        let (summary, error) = writer.finish()
        writer.receive(source)
        #expect(error == nil)
        #expect(summary.frames == 4)
        #expect(summary.peak == 1)
        #expect(summary.clippedSamples == 1)
        #expect(writer.snapshot().0.frames == 4)
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 4)
        #expect(file.processingFormat.channelCount == 1)
        let result = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4))
        try file.read(into: result)
        #expect(abs(try #require(result.floatChannelData)[0][1] - 0.5) < 0.0001)
    }

    @Test func changedInputFormatStopsWritingWithAnActionableError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioCaptureWriter(url: url, sampleRate: 44_100, channel: 0, bitDepth: 16)
        writer.begin()
        writer.receive(try buffer())
        let result = writer.finish()
        #expect(result.0.frames == 0)
        #expect(result.1 != nil)
    }

    @Test func silenceDoesNotProduceInvalidDecibels() {
        let summary = AudioRecordingSummary(frames: 48_000, sampleRate: 48_000)
        #expect(summary.duration == 1)
        #expect(summary.peakDecibels == nil)
    }
}
