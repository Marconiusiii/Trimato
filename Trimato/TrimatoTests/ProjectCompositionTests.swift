import AVFoundation
import Foundation
import Testing
@testable import Trimato

@Suite(.serialized)
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
        #expect(!result.videoComposition.instructions.isEmpty)
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
        #expect(abs(CMTimeGetSeconds(result.videoComposition.frameDuration) - (1 / 30)) < 0.000_001)
        let instructions = result.videoComposition.instructions.compactMap {
            $0 as? AVMutableVideoCompositionInstruction
        }
        #expect(instructions.count == result.videoComposition.instructions.count)
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
            abs(CMTimeGetSeconds(automaticResult.videoComposition.frameDuration) - (1_001.0 / 24_000.0))
                < 0.000_001
        )
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
}
