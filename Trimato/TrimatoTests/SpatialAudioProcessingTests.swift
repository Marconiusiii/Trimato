import AVFoundation
import Testing
@testable import Trimato

@MainActor @Suite(.serialized)
struct SpatialAudioProcessingTests {
    @Test(.enabled(if: IPhoneMediaTests.available))
    func processedCinematicAudioCanBeEditedAgain() async throws {
        let source = IPhoneMediaTests.sources.appendingPathComponent("4K_60fps.mov")
        let first = try await SpatialAudioRenderPlan(source: source, duration: 1,
            regions: [.init(sourceStart: 0, start: 0, duration: 1, gain: 0.5)]).render()
        defer { try? FileManager.default.removeItem(at: first) }
        let second = try await SpatialAudioRenderPlan(source: first, duration: 1,
            regions: [.init(sourceStart: 0, start: 0, duration: 1, gain: 0.5)]).render()
        defer { try? FileManager.default.removeItem(at: second) }
        for index in 0..<2 {
            let original = try await Self.samples(AVURLAsset(url: source), index: index)
            let result = try await Self.samples(AVURLAsset(url: second), index: index)
            #expect(result.values.count == 48_000 * original.channels)
            #expect(zip(result.values, original.values).allSatisfy { abs($0 - $1 * 0.25) < 0.000001 })
        }
    }

    @Test(.enabled(if: IPhoneMediaTests.available))
    func masterVolumeRebuildsSpatialPreview() async throws {
        let source = IPhoneMediaTests.sources.appendingPathComponent("4K_60fps.mov")
        var project = try await IPhoneMediaTests().project(source: source)
        let model = ProjectPlayerViewModel()
        model.player.isMuted = true
        defer { model.cancelPreparation(); model.player.replaceCurrentItem(with: nil) }
        model.prepare(project: project, mediaURLs: [project.media[0].id: source])
        for _ in 0..<300 {
            if !model.isPreparing { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(model.errorMessage == nil)
        project.masterVolumeDB = -6
        model.updateMix(project: project)
        for _ in 0..<300 {
            if !model.isPreparing { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!model.isPreparing)
        #expect(model.errorMessage == nil)
        let item = try #require(model.player.currentItem)
        for index in 0..<2 {
            let original = try await Self.samples(AVURLAsset(url: source), index: index)
            let result = try await Self.samples(item.asset, index: index)
            #expect(result.values.count == 48_000 * original.channels)
            let gain = Float(pow(10, -6.0 / 20))
            #expect(zip(result.values, original.values).allSatisfy { abs($0 - $1 * gain) < 0.000001 })
        }
    }

    @Test(.enabled(if: IPhoneMediaTests.available), arguments: ["4K_30fps.MOV", "4K_60fps.mov", "4K_120fps.MOV"])
    func volumeAndFadePreserveEverySpatialChannel(name: String) async throws {
        let source = IPhoneMediaTests.sources.appendingPathComponent(name)
        var project = try await IPhoneMediaTests().project(source: source)
        project.masterVolumeDB = -6
        let track = try #require(project.tracks.first { $0.kind == .audio })
        project.transitions.append(TimelineTransition(trackID: track.id, edge: .intro, kind: .audio(.fade),
            duration: ProjectTime(seconds: 0.5), trailingClipID: track.clips[0].id))
        let output = URL(fileURLWithPath: "/tmp/trimato-processed-" + name + ".mov")
        try await ProjectExporter.export(project: project, mediaURLs: [project.media[0].id: source], format: .hevcMovie,
            to: output, progress: { _ in }, preserveHDR: true)
        let asset = AVURLAsset(url: output)
        #expect(try await SpatialAudioPlan.detect(in: asset))
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(tracks.count == 2)
        #expect(try await asset.load(.trackGroups).contains { $0.trackIDs.count == 2 })
        for index in 0..<2 {
            let original = try await Self.samples(AVURLAsset(url: source), index: index)
            let rendered = try await Self.samples(asset, index: index)
            #expect(original.channels == rendered.channels)
            #expect(rendered.values.count == 48_000 * rendered.channels)
            var maximum = 0.0
            for i in rendered.values.indices {
                let time = Double(i / rendered.channels) / 48_000
                let level = Float(pow(10, -6.0 / 20)) * Float(min(time / 0.5, 1))
                maximum = max(maximum, abs(Double(rendered.values[i]) - Double(original.values[i] * level)))
            }
            #expect(maximum < 0.000001)
        }
        let preview = try await ProjectCompositionBuilder.build(project: project, mediaURLs: [project.media[0].id: source])
        defer { for url in preview.temporaryMediaURLs { try? FileManager.default.removeItem(at: url) } }
        let player = AVPlayer(playerItem: AVPlayerItem(asset: preview.playbackAsset))
        player.isMuted = true
        player.currentItem?.videoComposition = preview.playbackVideoComposition
        for _ in 0..<100 {
            if player.currentItem?.status != .unknown { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(player.currentItem?.status == .readyToPlay)
        player.replaceCurrentItem(with: nil)
    }

    @Test(.enabled(if: IPhoneMediaTests.available), arguments: [AudioTransitionType.crossFade, .fadeOutIn])
    func transitionMatchesTheExpectedSpatialBlend(type: AudioTransitionType) async throws {
        let source = IPhoneMediaTests.sources.appendingPathComponent("4K_60fps.mov")
        var project = try await IPhoneMediaTests().project(source: source)
        let first = SourceSegment(sourceRange: ProjectTimeRange(start: ProjectTime(seconds: 1), duration: ProjectTime(seconds: 1)))
        for index in project.tracks.indices where !project.tracks[index].clips.isEmpty { project.tracks[index].clips[0].segments = [first] }
        project.synchronizeTracksToLegacyTimeline()
        _ = try project.append(asset: project.media[0], segments: [SourceSegment(sourceRange: ProjectTimeRange(start: ProjectTime(seconds: 3), duration: ProjectTime(seconds: 1)))])
        let track = try #require(project.tracks.first { $0.kind == .audio })
        project.transitions.append(TimelineTransition(trackID: track.id, edge: .between, kind: .audio(type), duration: ProjectTime(seconds: 0.4), leadingClipID: track.clips[0].id, trailingClipID: track.clips[1].id))
        let output = URL(fileURLWithPath: "/tmp/trimato-spatial-" + type.rawValue + ".mov")
        try await ProjectExporter.export(project: project, mediaURLs: [project.media[0].id: source], format: .hevcMovie, to: output, progress: { _ in })
        for index in 0..<2 {
            let original = try await Self.samples(AVURLAsset(url: source), index: index)
            let result = try await Self.samples(AVURLAsset(url: output), index: index)
            #expect(result.channels == original.channels)
            #expect(result.values.count == 96_000 * result.channels)
            var error = 0.0
            for frame in 0..<96_000 {
                let time = Double(frame) / 48_000
                for channel in 0..<result.channels {
                    func sample(_ position: Int) -> Float { original.values[position * result.channels + channel] }
                    let expected: Float
                    if frame < 38_400 { expected = sample(48_000 + frame) }
                    else if frame >= 57_600 { expected = sample(96_000 + frame) }
                    else if type == .crossFade {
                        let fraction = Float((time - 0.8) / 0.4)
                        expected = sample(48_000 + frame) * (1 - fraction) + sample(96_000 + frame) * fraction
                    } else if frame < 48_000 { expected = sample(48_000 + frame) * Float((1 - time) / 0.2) }
                    else { expected = sample(96_000 + frame) * Float((time - 1) / 0.2) }
                    error = max(error, abs(Double(result.values[frame * result.channels + channel]) - Double(expected)))
                }
            }
            #expect(error < 0.000001)
        }
    }

    static func samples(_ asset: AVAsset, index: Int) async throws -> (channels: Int, values: [Float]) {
        let track = try await asset.loadTracks(withMediaType: .audio)[index]
        let description = try #require(try await track.load(.formatDescriptions).first)
        let format = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        let layout = try SpatialAudioPlan.channelLayout(description)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: SpatialAudioRenderPlan.isNativeFloat(format) ? nil : [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.mSampleRate, AVNumberOfChannelsKey: format.mChannelsPerFrame,
            AVChannelLayoutKey: layout, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        #expect(reader.startReading())
        defer { reader.cancelReading() }
        var values: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            let block = try #require(CMSampleBufferGetDataBuffer(sample))
            var data = Data(count: CMBlockBufferGetDataLength(block))
            let count = data.count
            _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!) }
            data.withUnsafeBytes { bytes in
                for offset in stride(from: 0, to: count, by: 4) { values.append(bytes.loadUnaligned(fromByteOffset: offset, as: Float.self)) }
            }
        }
        #expect(reader.status == .completed)
        return (Int(format.mChannelsPerFrame), values)
    }
}
