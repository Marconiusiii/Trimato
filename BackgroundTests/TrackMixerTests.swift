import Testing
import Foundation
import AVFoundation
@testable import TrimatoMediaSupport

struct TrackMixerTests {
    @Test func channelMatrix() throws {
        var mix = TrackMixSettings()
        #expect(mix.matrix().apply(left: 0.2, right: -0.4).0 == 0.2)
        mix.routing = .left
        #expect(mix.matrix().apply(left: 0.2, right: -0.4).1 == 0.2)
        mix.routing = .right
        #expect(mix.matrix().apply(left: 0.2, right: -0.4).0 == -0.4)
        mix.routing = .swap
        #expect(mix.matrix().apply(left: 0.2, right: -0.4).1 == 0.2)
        mix = .neutral; mix.width = 0
        let mono = mix.matrix().apply(left: 0.2, right: 0.4)
        #expect(abs(mono.0 - 0.3) < 0.0001 && mono.0 == mono.1)
        mix = .neutral; mix.pan = -1
        #expect(abs(mix.matrix().apply(left: 0.2, right: 0.4).1) < 0.000001)
        mix = .neutral; mix.balance = 1
        #expect(mix.matrix().apply(left: 0.2, right: 0.4).0 == 0)
        mix.volumeDB = -6; mix.balance = 0
        #expect(abs(mix.matrix(masterDB: -6).ll - pow(10, -12.0/20)) < 0.0001)
        #expect(mix.matrix(silent: true) == .silent)
        #expect(try JSONDecoder().decode(TrackMixSettings.self, from: JSONEncoder().encode(mix)) == mix)
    }

    @Test(arguments: TrackChannelRouting.allCases) func audioTapProcessesReaderAndExport(routing: TrackChannelRouting) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        buffer.frameLength = 48000
        for i in 0..<48000 {
            buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 48000) * 0.2)
            buffer.floatChannelData![1][i] = Float(sin(Double(i) * 2 * .pi * 880 / 48000) * 0.4)
        }
        var fileSettings = format.settings
        fileSettings[AVLinearPCMIsNonInterleaved] = false
        do { let file = try AVAudioFile(forWriting: source, settings: fileSettings); try file.write(from: buffer) }
        let asset = AVURLAsset(url: source)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.setVolume(0.5, at: .zero)
        var settings = TrackMixSettings(); settings.routing = routing; settings.volumeDB = -6
        let processor = TrackMixProcessor(trackID: UUID(), matrix: settings.matrix(masterDB: -6))
        parameters.audioTapProcessor = try processor.makeTap()
        let mix = AVMutableAudioMix(); mix.inputParameters = [parameters]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [AVFormatIDKey:kAudioFormatLinearPCM, AVLinearPCMIsFloatKey:true, AVLinearPCMBitDepthKey:32, AVLinearPCMIsNonInterleaved:false, AVNumberOfChannelsKey:2])
        output.audioMix = mix; reader.add(output)
        #expect(reader.startReading())
        var peaks = [Float(0), Float(0)]
        while let sample = output.copyNextSampleBuffer(), let data = CMSampleBufferGetDataBuffer(sample) {
            var length = 0; var pointer: UnsafeMutablePointer<Int8>?
            #expect(CMBlockBufferGetDataPointer(data, atOffset:0, lengthAtOffsetOut:nil, totalLengthOut:&length, dataPointerOut:&pointer) == noErr)
            let floats = UnsafeRawPointer(pointer!).assumingMemoryBound(to:Float.self)
            for i in 0..<(length/4) { peaks[i%2] = max(peaks[i%2],abs(floats[i])) }
        }
        #expect(reader.status == .completed)
        let expected: [Float] = switch routing {
        case .both: [0.025119, 0.050238]
        case .left: [0.025119, 0.025119]
        case .right: [0.050238, 0.050238]
        case .swap: [0.050238, 0.025119]
        }
        #expect(abs(peaks[0]-expected[0]) < 0.002)
        #expect(abs(peaks[1]-expected[1]) < 0.002)
        // Changing the existing processor updates subsequent audio without replacing its tap.
        processor.update(.silent)
        let liveReader = try AVAssetReader(asset: asset)
        let liveOutput = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [AVFormatIDKey:kAudioFormatLinearPCM, AVLinearPCMIsFloatKey:true, AVLinearPCMBitDepthKey:32, AVLinearPCMIsNonInterleaved:false, AVNumberOfChannelsKey:2])
        liveOutput.audioMix = mix; liveReader.add(liveOutput)
        #expect(liveReader.startReading())
        var samplesRead = 0, tailPeak = Float(0)
        while let sample = liveOutput.copyNextSampleBuffer(), let data = CMSampleBufferGetDataBuffer(sample) {
            var length = 0; var pointer: UnsafeMutablePointer<Int8>?
            #expect(CMBlockBufferGetDataPointer(data, atOffset:0, lengthAtOffsetOut:nil, totalLengthOut:&length, dataPointerOut:&pointer) == noErr)
            let floats = UnsafeRawPointer(pointer!).assumingMemoryBound(to:Float.self)
            for i in 0..<(length/4) {
                if samplesRead > 2000 { tailPeak = max(tailPeak,abs(floats[i])) }
                samplesRead += 1
            }
        }
        #expect(liveReader.status == .completed)
        #expect(samplesRead > 90000)
        #expect(tailPeak < 0.00001)
        // Export uses a separate tap so no playback smoothing history can affect its start.
        parameters.audioTapProcessor = try TrackMixProcessor(trackID: UUID(), matrix: settings.matrix(masterDB: -6)).makeTap()
        mix.inputParameters = [parameters]
        let export = try #require(AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A))
        export.audioMix = mix
        let destination = directory.appendingPathComponent("export.m4a")
        try await export.export(to: destination, as: .m4a)
        let file = try AVAudioFile(forReading: destination)
        let rendered = AVAudioPCMBuffer(pcmFormat:file.processingFormat, frameCapacity:AVAudioFrameCount(file.length))!
        try file.read(into:rendered)
        var exportPeaks = [Float(0),Float(0)]
        for channel in 0..<2 { for i in 0..<Int(rendered.frameLength) {
            exportPeaks[channel] = max(exportPeaks[channel],abs(rendered.floatChannelData![channel][i]))
        } }
        #expect(abs(exportPeaks[0]-expected[0]) < 0.005)
        #expect(abs(exportPeaks[1]-expected[1]) < 0.005)
    }
}

extension TrackMixerTests {
    @Test func integerMonoAndFloatingPointStereo() {
        let state = TrackMixProcessor(trackID: UUID(), matrix: StereoMixMatrix(ll: 0.5, lr: 0, rl: 0, rr: 0.5))
        var integers: [Int16] = [8192, -16384, 32766, -32768]
        var format = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        state.prepare(format)
        integers.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            state.process(&list, frames: 4)
        }
        #expect(integers == [4096, -8192, 16383, -16384])
        var doubles = [0.2, -0.4, 0.6, -0.8]
        format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        format.mChannelsPerFrame = 2
        format.mBitsPerChannel = 64
        format.mBytesPerFrame = 16; format.mBytesPerPacket = 16
        state.prepare(format)
        doubles.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            state.process(&list, frames: 2)
        }
        #expect(doubles == [0.1, -0.2, 0.3, -0.4])
    }
}
