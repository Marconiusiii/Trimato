import AVFoundation
import Foundation
import Testing
@testable import Trimato

@Suite(.serialized)
@MainActor
struct ProjectCompositionTests {
    @Test func projectWithoutCutawaysExportsACompleteMP4() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.mov")
        let outputURL = directory.appendingPathComponent("finished.mp4")
        try await makeFixture(at: sourceURL, color: "green", frequency: 440, duration: 1)

        var asset = fixtureAsset(name: "Source", duration: 1)
        asset.originalPath = sourceURL.path
        var project = TrimatoProject(name: "No Cutaways")
        project.format = ProjectFormat(mode: .custom, width: 320, height: 180, frameRate: 24)
        project.media = [asset]
        _ = try project.append(asset: asset)

        let composition = try await ProjectCompositionBuilder.build(
            project: project,
            mediaURLs: [asset.id: sourceURL],
            purpose: .finalExport
        )
        #expect(try await composition.composition.loadTracks(withMediaType: .video).count == 1)
        #expect(try await composition.composition.loadTracks(withMediaType: .audio).count == 1)

        try await ProjectExporter.export(
            project: project,
            mediaURLs: [asset.id: sourceURL],
            format: .h264MP4,
            to: outputURL,
            progress: { _ in }
        )
        let outputAsset = AVURLAsset(url: outputURL)
        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        #expect(try await !outputAsset.loadTracks(withMediaType: .video).isEmpty)
        #expect(try await !outputAsset.loadTracks(withMediaType: .audio).isEmpty)
    }

    @Test(arguments: ExportFormat.projectFormats)
    func projectExportsEachAvailableFormat(format: ExportFormat) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.mov")
        let outputURL = directory
            .appendingPathComponent("finished")
            .appendingPathExtension(format.fileExtension)
        try await makeFixture(at: sourceURL, color: "blue", frequency: 440, duration: 0.5)

        var asset = fixtureAsset(name: "Source", duration: 0.5)
        asset.originalPath = sourceURL.path
        var project = TrimatoProject(name: "Formats")
        project.format = ProjectFormat(mode: .custom, width: 320, height: 180, frameRate: 24)
        project.media = [asset]
        _ = try project.append(asset: asset)

        try await ProjectExporter.export(
            project: project,
            mediaURLs: [asset.id: sourceURL],
            format: format,
            to: outputURL,
            progress: { _ in }
        )

        let outputAsset = AVURLAsset(url: outputURL)
        let audioTracks = try await outputAsset.loadTracks(withMediaType: .audio)
        let videoTracks = try await outputAsset.loadTracks(withMediaType: .video)
        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        #expect(!audioTracks.isEmpty)
        #expect(format.isAudioOnly ? videoTracks.isEmpty : !videoTracks.isEmpty)
    }

    @Test func multiSourceCompositionAndCutawayKeepPrimaryDuration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let interviewURL = directory.appendingPathComponent("interview.mov")
        let cutawayURL = directory.appendingPathComponent("cutaway.mp4")
        try await makeFixture(at: interviewURL, color: "red", frequency: 440, duration: 2)
        try await makeFixture(
            at: cutawayURL,
            color: "blue",
            frequency: 880,
            duration: 0.5,
            size: "90x160",
            rate: "60",
            videoCodecArguments: ["-c:v", "h264_videotoolbox", "-allow_sw", "1", "-tag:v", "avc1"]
        )

        var interview = fixtureAsset(name: "Interview", duration: 2)
        interview.originalPath = interviewURL.path
        var cutaway = fixtureAsset(name: "Cutaway", duration: 0.5)
        cutaway.originalPath = cutawayURL.path
        cutaway.naturalWidth = 90
        cutaway.naturalHeight = 160
        cutaway.frameRate = 60

        var project = TrimatoProject(name: "Composition")
        project.format = ProjectFormat(mode: .custom, width: 320, height: 180, frameRate: 24)
        project.media = [interview, cutaway]
        _ = try project.append(asset: interview)
        _ = try project.addCutaway(
            asset: cutaway,
            at: ProjectTime(seconds: 0.75),
            audioMode: .sourceAudio
        )

        let result = try await ProjectCompositionBuilder.build(
            project: project,
            mediaURLs: [interview.id: interviewURL, cutaway.id: cutawayURL]
        )
        let duration = try await result.composition.load(.duration)

        #expect(abs(CMTimeGetSeconds(duration) - 2) < 0.02)
        #expect(result.audioMix != nil)
        #expect(!(try #require(result.videoComposition)).instructions.isEmpty)
    }

    @Test func mixedResolutionOrientationAndFrameRateUseTheProjectFormat() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let landscapeURL = directory.appendingPathComponent("landscape.mov")
        let portraitURL = directory.appendingPathComponent("portrait.mp4")
        let outputURL = directory.appendingPathComponent("mixed.mp4")
        try await makeFixture(
            at: landscapeURL,
            color: "red",
            frequency: 440,
            duration: 0.5,
            size: "320x180",
            rate: "24000/1001"
        )
        try await makeFixture(
            at: portraitURL,
            color: "blue",
            frequency: 880,
            duration: 0.5,
            size: "90x160",
            rate: "60",
            videoCodecArguments: ["-c:v", "h264_videotoolbox", "-allow_sw", "1", "-tag:v", "avc1"]
        )

        var landscape = fixtureAsset(name: "Landscape", duration: 0.5)
        landscape.originalPath = landscapeURL.path
        landscape.naturalWidth = 320
        landscape.naturalHeight = 180
        landscape.frameRate = 24_000.0 / 1_001.0
        var portrait = fixtureAsset(name: "Portrait", duration: 0.5)
        portrait.originalPath = portraitURL.path
        portrait.naturalWidth = 90
        portrait.naturalHeight = 160
        portrait.frameRate = 60

        var project = TrimatoProject(name: "Mixed Media")
        project.format = ProjectFormat(mode: .custom, width: 320, height: 180, frameRate: 30)
        project.media = [landscape, portrait]
        _ = try project.append(asset: landscape)
        _ = try project.append(asset: portrait)

        let result = try await ProjectCompositionBuilder.build(
            project: project,
            mediaURLs: [landscape.id: landscapeURL, portrait.id: portraitURL],
            purpose: .finalExport
        )
        let videoComposition = try #require(result.videoComposition)
        #expect(abs(CMTimeGetSeconds(videoComposition.frameDuration) - (1 / 30)) < 0.000_001)
        let instructions = videoComposition.instructions.compactMap {
            $0 as? AVMutableVideoCompositionInstruction
        }
        #expect(instructions.count == videoComposition.instructions.count)
        #expect(instructions.allSatisfy { $0.backgroundColor != nil })

        let portraitTracks = try await AVURLAsset(url: portraitURL).loadTracks(withMediaType: .video)
        let portraitTrack = try #require(portraitTracks.first)
        let portraitTransform = try await ProjectCompositionBuilder.displayTransform(
            for: portraitTrack,
            renderSize: CGSize(width: 320, height: 180)
        )
        let fittedPortrait = CGRect(x: 0, y: 0, width: 90, height: 160).applying(portraitTransform)
        #expect(abs(fittedPortrait.width - 101.25) < 0.01)
        #expect(abs(fittedPortrait.height - 180) < 0.01)
        #expect(abs(fittedPortrait.minX - 109.375) < 0.01)
        #expect(abs(fittedPortrait.minY) < 0.01)

        try await ProjectExporter.export(
            project: project,
            mediaURLs: [landscape.id: landscapeURL, portrait.id: portraitURL],
            format: .h264MP4,
            to: outputURL,
            progress: { _ in }
        )
        let outputTracks = try await AVURLAsset(url: outputURL).loadTracks(withMediaType: .video)
        let outputTrack = try #require(outputTracks.first)
        let outputSize = try await outputTrack.load(.naturalSize)
        let outputRate = try await outputTrack.load(.nominalFrameRate)
        #expect(outputSize == CGSize(width: 320, height: 180))
        #expect(abs(Double(outputRate) - 30) < 0.1)

        var automaticProject = project
        automaticProject.applyProjectFormat(ProjectFormat(mode: .automatic))
        #expect(automaticProject.format.width == 320)
        #expect(automaticProject.format.height == 180)
        #expect(abs((automaticProject.format.frameRate ?? 0) - (24_000.0 / 1_001.0)) < 0.001)
        let automaticResult = try await ProjectCompositionBuilder.build(
            project: automaticProject,
            mediaURLs: [landscape.id: landscapeURL, portrait.id: portraitURL],
            purpose: .finalExport
        )
        #expect(
            abs(CMTimeGetSeconds((try #require(automaticResult.videoComposition)).frameDuration) - (1_001.0 / 24_000.0))
                < 0.000_001
        )
    }

    @Test func audioOnlyProjectPreviewsAndExportsWithoutAProjectCanvas() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("narration.wav")
        let outputURL = directory.appendingPathComponent("finished.wav")
        try await makeAudioFixture(at: sourceURL, frequency: 440, duration: 0.5)

        var asset = fixtureAsset(name: "Narration", duration: 0.5)
        asset.originalPath = sourceURL.path
        asset.naturalWidth = nil
        asset.naturalHeight = nil
        asset.frameRate = nil
        asset.hasAudio = true
        var project = TrimatoProject(name: "Audio Only")
        project.media = [asset]
        _ = try project.append(asset: asset)

        #expect(!project.format.isResolved)
        let result = try await ProjectCompositionBuilder.build(
            project: project,
            mediaURLs: [asset.id: sourceURL]
        )
        #expect(result.videoComposition == nil)
        #expect(try await result.composition.loadTracks(withMediaType: .video).isEmpty)
        #expect(try await result.composition.loadTracks(withMediaType: .audio).count == 1)

        try await ProjectExporter.export(
            project: project,
            mediaURLs: [asset.id: sourceURL],
            format: .wav,
            to: outputURL,
            progress: { _ in }
        )
        let output = AVURLAsset(url: outputURL)
        #expect(try await output.loadTracks(withMediaType: .video).isEmpty)
        #expect(try await output.loadTracks(withMediaType: .audio).count == 1)
    }

    @Test func videoSourceOnAnAudioTrackContributesAudioWithoutPicture() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("interview.mp4")
        try await makeFixture(at: sourceURL, color: "blue", frequency: 440, duration: 0.5)

        var asset = fixtureAsset(name: "Interview", duration: 0.5)
        asset.originalPath = sourceURL.path
        var project = TrimatoProject(name: "Extracted Audio")
        project.media = [asset]
        let audioTrackID = project.createTrack(kind: .audio, name: "Interview Audio")
        _ = try project.append(asset: asset, toTrack: audioTrackID)

        let result = try await ProjectCompositionBuilder.build(
            project: project,
            mediaURLs: [asset.id: sourceURL]
        )

        #expect(!(try await result.composition.loadTracks(withMediaType: .audio)).isEmpty)
        #expect((try await result.composition.loadTracks(withMediaType: .video)).isEmpty)
        #expect(result.videoComposition == nil)
        #expect(project.format.width == nil)
        #expect(project.format.height == nil)
    }

    @Test func audioFirstMixedTimelineResolvesFromVideoAndKeepsAudioOnlySpan() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("intro.wav")
        let videoURL = directory.appendingPathComponent("picture.mov")
        try await makeAudioFixture(at: audioURL, frequency: 220, duration: 0.5)
        try await makeFixture(at: videoURL, color: "purple", frequency: 440, duration: 0.5)

        var audio = fixtureAsset(name: "Intro", duration: 0.5)
        audio.originalPath = audioURL.path
        audio.naturalWidth = nil
        audio.naturalHeight = nil
        audio.frameRate = nil
        var video = fixtureAsset(name: "Picture", duration: 0.5)
        video.originalPath = videoURL.path
        var project = TrimatoProject(name: "Mixed")
        project.media = [audio, video]
        _ = try project.append(asset: audio)
        #expect(!project.format.isResolved)
        _ = try project.append(asset: video)
        #expect(project.format.width == video.naturalWidth)
        #expect(project.format.height == video.naturalHeight)

        let result = try await ProjectCompositionBuilder.build(
            project: project,
            mediaURLs: [audio.id: audioURL, video.id: videoURL],
            purpose: .finalExport
        )
        let videoComposition = try #require(result.videoComposition)
        #expect(abs((try await result.composition.load(.duration)).seconds - 1) < 0.02)
        let firstInstruction = try #require(videoComposition.instructions.first as? AVMutableVideoCompositionInstruction)
        #expect(firstInstruction.backgroundColor != nil)
    }

    @Test func negativeAdditionalAudioPositionUsesOnlyTheVisibleSourceForPreview() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("music.wav")
        try await makeAudioFixture(at: sourceURL, frequency: 440, duration: 1)

        var music = fixtureAsset(name: "Music", duration: 1)
        music.originalPath = sourceURL.path
        music.naturalWidth = nil
        music.naturalHeight = nil
        music.frameRate = nil
        var project = TrimatoProject(name: "Positioned Audio")
        project.media = [music]
        let trackID = project.createTrack(kind: .audio, name: "Music")
        let clipID = try project.append(asset: music, toTrack: trackID)
        try project.updateAudioSettings(
            clipID: clipID,
            settings: AudioClipSettings(gainDecibels: 2)
        )
        try project.positionAdditionalTrackClip(
            id: clipID,
            edge: .tail,
            at: ProjectTime(seconds: 0.25)
        )

        let result = try await ProjectCompositionBuilder.build(
            project: project,
            mediaURLs: [music.id: sourceURL]
        )
        let track = try #require(try await result.composition.loadTracks(withMediaType: .audio).first)
        let segment = try #require(track.segments.first(where: { !$0.isEmpty }))

        #expect(abs(track.timeRange.duration.seconds - 0.25) < 0.03)
        #expect(abs(segment.timeMapping.source.start.seconds - 0.75) < 0.03)
        #expect(abs(segment.timeMapping.target.start.seconds) < 0.01)
    }

    @Test func negativeAdditionalVideoPositionUsesOnlyTheVisibleSourceForPreview() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("overlay.mov")
        try await makeFixture(at: sourceURL, color: "orange", frequency: 440, duration: 1)

        var overlay = fixtureAsset(name: "Overlay", duration: 1)
        overlay.originalPath = sourceURL.path
        var project = TrimatoProject(name: "Positioned Video")
        project.format = ProjectFormat(mode: .custom, width: 320, height: 180, frameRate: 24)
        project.media = [overlay]
        let trackID = project.createTrack(kind: .video, name: "Overlay")
        let clipID = try project.append(asset: overlay, toTrack: trackID)
        try project.positionAdditionalTrackClip(
            id: clipID,
            edge: .tail,
            at: ProjectTime(seconds: 0.25)
        )

        let result = try await ProjectCompositionBuilder.build(
            project: project,
            mediaURLs: [overlay.id: sourceURL]
        )
        let track = try #require(try await result.composition.loadTracks(withMediaType: .video).first)
        let segment = try #require(track.segments.first(where: { !$0.isEmpty }))

        #expect(abs(track.timeRange.duration.seconds - 0.25) < 0.03)
        #expect(abs(segment.timeMapping.source.start.seconds - 0.75) < 0.03)
        #expect(abs(segment.timeMapping.target.start.seconds) < 0.01)
    }

    @Test(arguments: [ExportFormat.wav, .h264MP4])
    func mutedPrimaryTrackExportsSilenceIncludingItsCrossfade(format: ExportFormat) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.mov")
        try await makeFixture(at: sourceURL, color: "green", frequency: 440, duration: 6)
        var asset = fixtureAsset(name: "Footage", duration: 6)
        asset.originalPath = sourceURL.path
        var project = TrimatoProject()
        project.format = ProjectFormat(mode: .custom, width: 320, height: 180, frameRate: 24)
        project.media = [asset]
        _ = try project.append(asset: asset, segments: [SourceSegment(sourceRange: ProjectTimeRange(start: ProjectTime(seconds: 1), duration: ProjectTime(seconds: 2)))])
        _ = try project.append(asset: asset, segments: [SourceSegment(sourceRange: ProjectTimeRange(start: ProjectTime(seconds: 3), duration: ProjectTime(seconds: 2)))])
        let audioIndex = try #require(project.tracks.firstIndex { $0.kind == .audio })
        let audioTrack = project.tracks[audioIndex]
        try project.addTransition(TimelineTransition(trackID: audioTrack.id, edge: .between, kind: .audio(.crossFade), duration: ProjectTime(seconds: 1), leadingClipID: audioTrack.sortedClips[0].id, trailingClipID: audioTrack.sortedClips[1].id))
        project.tracks[audioIndex].isMuted = true
        let mutedURL = directory.appendingPathComponent("muted").appendingPathExtension(format.fileExtension)
        try await ProjectExporter.export(project: project, mediaURLs: [asset.id: sourceURL], format: format, to: mutedURL, progress: { _ in })
        #expect(try await peakVolume(mutedURL) < -80)
        #expect(abs(try await AVURLAsset(url: mutedURL).load(.duration).seconds - 4) < 0.1)
        project.tracks[audioIndex].isMuted = false
        let audibleURL = directory.appendingPathComponent("audible").appendingPathExtension(format.fileExtension)
        try await ProjectExporter.export(project: project, mediaURLs: [asset.id: sourceURL], format: format, to: audibleURL, progress: { _ in })
        #expect(try await peakVolume(audibleURL) > -40)
    }

    @Test func muteIsScopedToOneTrackAndCutawayAudioCanBeMuted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.mov")
        try await makeFixture(at: sourceURL, color: "green", frequency: 440, duration: 4)
        var asset = fixtureAsset(name: "Footage", duration: 4)
        asset.originalPath = sourceURL.path
        var project = TrimatoProject()
        project.format = ProjectFormat(mode: .custom, width: 320, height: 180, frameRate: 24)
        project.media = [asset]
        _ = try project.append(asset: asset)
        let cutawayID = try project.addCutaway(asset: asset, segments: [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 2)))], at: ProjectTime(seconds: 1), audioMode: .sourceAudio)
        let primary = try #require(project.tracks.firstIndex { $0.role == .primaryAudio })
        let cutawayAudio = try #require(project.tracks.firstIndex { $0.kind == .audio && $0.role == .additional })
        #expect(project.tracks[cutawayAudio].clips.first?.linkedClipID == cutawayID)
        project.tracks[primary].isMuted = true
        let output = directory.appendingPathComponent("audible.wav")
        try await ProjectExporter.export(project: project, mediaURLs: [asset.id: sourceURL], format: .wav, to: output, progress: { _ in })
        #expect(try await peakVolume(output) > -40)
        project.tracks[cutawayAudio].isMuted = true
        let silent = directory.appendingPathComponent("silent.wav")
        try await ProjectExporter.export(project: project, mediaURLs: [asset.id: sourceURL], format: .wav, to: silent, progress: { _ in })
        #expect(try await peakVolume(silent) < -80)
    }

    @Test func compositionUsesReorderedPrimaryTrackSourceRanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.mov")
        try await makeFixture(at: sourceURL, color: "blue", frequency: 440, duration: 4)
        var asset = fixtureAsset(name: "Footage", duration: 4)
        asset.originalPath = sourceURL.path
        var project = TrimatoProject()
        project.format = ProjectFormat(mode: .custom, width: 320, height: 180, frameRate: 24)
        project.media = [asset]
        let first = try project.append(asset: asset, segments: [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 1)))])
        let second = try project.append(asset: asset, segments: [SourceSegment(sourceRange: ProjectTimeRange(start: ProjectTime(seconds: 2), duration: ProjectTime(seconds: 1)))])
        try project.moveTrackClip(id: first, after: second)
        let result = try await ProjectCompositionBuilder.build(project: project, mediaURLs: [asset.id: sourceURL])
        defer { for url in result.temporaryMediaURLs { try? FileManager.default.removeItem(at: url) } }
        let video = try #require(try await result.composition.loadTracks(withMediaType: .video).first)
        let segments = try await video.load(.segments).filter { !$0.isEmpty }
        #expect(segments.map { $0.timeMapping.source.start.seconds } == [2, 0])
    }

    private func peakVolume(_ url: URL) async throws -> Double {
        let result = try await FFmpegRunner.run(tool: .ffmpeg, arguments: [
            "-hide_banner", "-nostdin", "-i", url.path, "-af", "volumedetect", "-f", "null", "-"
        ])
        let line = try #require(result.standardError.components(separatedBy: "\n").first { $0.contains("max_volume:") })
        let value = try #require(line.components(separatedBy: "max_volume:").last?.split(separator: " ").first)
        return try #require(Double(value))
    }

    private func makeFixture(
        at url: URL,
        color: String,
        frequency: Int,
        duration: Double,
        size: String = "320x180",
        rate: String = "24",
        videoCodecArguments: [String] = ["-c:v", "mpeg4"]
    ) async throws {
        var arguments = [
            "-hide_banner", "-nostdin", "-y",
            "-f", "lavfi", "-i", "color=c=\(color):size=\(size):rate=\(rate)",
            "-f", "lavfi", "-i", "sine=frequency=\(frequency):sample_rate=48000",
            "-t", String(duration)
        ]
        arguments += videoCodecArguments
        arguments += ["-c:a", "aac", url.path]
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: arguments)
    }

    private func makeAudioFixture(at url: URL, frequency: Int, duration: Double) async throws {
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: [
            "-hide_banner", "-nostdin", "-y",
            "-f", "lavfi", "-i", "sine=frequency=\(frequency):sample_rate=48000",
            "-t", String(duration),
            "-c:a", "pcm_s16le",
            url.path,
        ])
    }
}
