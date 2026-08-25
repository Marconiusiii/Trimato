import AVFoundation
import Foundation
import Testing
@testable import Trimato

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
        let cutawayURL = directory.appendingPathComponent("cutaway.mov")
        try await makeFixture(at: interviewURL, color: "red", frequency: 440, duration: 2)
        try await makeFixture(at: cutawayURL, color: "blue", frequency: 880, duration: 0.5)

        var interview = fixtureAsset(name: "Interview", duration: 2)
        interview.originalPath = interviewURL.path
        var cutaway = fixtureAsset(name: "Cutaway", duration: 0.5)
        cutaway.originalPath = cutawayURL.path

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

    private func makeFixture(
        at url: URL,
        color: String,
        frequency: Int,
        duration: Double
    ) async throws {
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: [
            "-hide_banner", "-nostdin", "-y",
            "-f", "lavfi", "-i", "color=c=\(color):size=320x180:rate=24",
            "-f", "lavfi", "-i", "sine=frequency=\(frequency):sample_rate=48000",
            "-t", String(duration), "-c:v", "mpeg4", "-c:a", "aac", url.path
        ])
    }
}
