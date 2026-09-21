import AppKit
import AVFoundation
import ImageIO
import Foundation
@testable import Trimato

@main struct MarkerFrameExportCheck {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var definition = GeneratorDefinition()
        definition.kind = .solidColor
        definition.color = .red
        definition.width = 320
        definition.height = 180
        definition.frameRate = 30
        definition.duration = ProjectTime(seconds: 2)
        let asset = definition.assetRecord()
        var project = TrimatoProject(name: "Frame & web <check>")
        project.format = ProjectFormat(mode: .custom, width: 320, height: 180, frameRate: 30)
        project.media = [asset]
        _ = try project.append(asset: asset)
        let originalPreview = ProjectPreviewInput(project)
        let first = project.insertMarker(at: ProjectTime(seconds: 0.75))
        let second = project.insertMarker(at: ProjectTime(seconds: 0.25))
        precondition(project.markerTrack!.sortedMarkers.map(\.id) == [second.id, first.id])
        precondition(ProjectPreviewInput(project) == originalPreview)
        precondition(!project.markerTrack!.isMagnetic)
        let decoded = try JSONDecoder().decode(TrimatoProject.self, from: JSONEncoder().encode(project))
        precondition(decoded.markerTrack == project.markerTrack)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("marker-frame-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let frame = try await ProjectFrameExporter.png(project: project, mediaURLs: [:], at: first.time, captions: false)
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(frame as CFData, nil)!, 0, nil)!
        precondition(image.width == 320 && image.height == 180)
        try project.addCaptionCues([CaptionCue(start: .zero, end: ProjectTime(seconds: 1), text: "Caption")])
        let captioned = try await ProjectFrameExporter.png(project: project, mediaURLs: [:], at: first.time, captions: true)
        precondition(captioned != frame, "Frame captions were not rendered")
        if let preview = ProcessInfo.processInfo.environment["TRIMATO_FRAME_PREVIEW"] {
            try captioned.write(to: URL(fileURLWithPath: preview))
        }
        let noCaption = try await ProjectFrameExporter.png(project: project, mediaURLs: [:], at: ProjectTime(seconds: 1.5), captions: true)
        precondition(noCaption == frame, "Caption extended beyond its cue")
        print("PNG full dimensions, caption inclusion and time boundaries passed")
        try await ProjectExporter.export(project: decoded, mediaURLs: [:],
            format: .h264MP4, to: directory.appendingPathComponent("generated.mp4"), audioMode: .highQualityStereo,
            progress: { _ in }, preserveHDR: false, webOptimized: true)
        print("Generated-picture web movie passed")
        let movieSource = directory.appendingPathComponent("source.mp4")
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-f", "lavfi", "-i", "color=c=red:s=320x180:r=30:d=2", "-c:v", "h264_videotoolbox", "-pix_fmt", "yuv420p", movieSource.path])
        var imported = decoded
        imported.media[0].generator = nil
        imported.media[0].originalPath = movieSource.path
        let movieURLs = [asset.id: movieSource]
        try await ProjectExporter.export(project: imported, mediaURLs: movieURLs, timeRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 1)),
            format: .h264MP4, to: directory.appendingPathComponent("video.mp4"), audioMode: .highQualityStereo, progress: { _ in }, preserveHDR: false, webOptimized: true)
        let video = AVURLAsset(url: directory.appendingPathComponent("video.mp4"))
        let duration = try await video.load(.duration).seconds
        precondition(abs(duration - 1) < 0.05)
        print("Web H.264 movie and range duration passed")
        let wav = directory.appendingPathComponent("tone.wav")
        try InterfaceSounds.wave(notes: [440], noteLength: 1, volume: 0.1).write(to: wav)
        let audio = MediaAssetRecord(name: "Tone", originalPath: wav.path, duration: ProjectTime(seconds: 1), hasAudio: true,
            sourceEdit: [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 1)))])
        var mix = TrimatoProject(name: "Mix")
        mix.media = [audio]
        let a = mix.createTrack(kind: .audio)
        let b = mix.createTrack(kind: .audio)
        _ = try mix.append(asset: audio, toTrack: a)
        _ = try mix.append(asset: audio, toTrack: b)
        let both = directory.appendingPathComponent("both.wav")
        try await ProjectExporter.export(project: mix, mediaURLs: [audio.id: wav], format: .wav24, to: both, audioMode: .highQualityStereo, progress: { _ in })
        mix.tracks[1].isMuted = true
        let one = directory.appendingPathComponent("one.wav")
        try await ProjectExporter.export(project: mix, mediaURLs: [audio.id: wav], format: .wav24, to: one, audioMode: .highQualityStereo, progress: { _ in })
        func peak(_ url: URL) throws -> Float {
            let file = try AVAudioFile(forReading: url)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            let samples = buffer.floatChannelData![0]
            return (0..<Int(buffer.frameLength)).map { abs(samples[$0]) }.max()!
        }
        let single = try peak(one), combined = try peak(both)
        precondition(abs(combined / single - 2) < 0.05, "Tracks were not mixed, or mute was ignored")
        print("Two-track audio-only mix and track mute passed")
        imported.media.append(audio)
        let audioTrack = imported.createTrack(kind: .audio)
        _ = try imported.append(asset: audio, toTrack: audioTrack)
        let avOutput = directory.appendingPathComponent("web-audio.mp4")
        try await ProjectExporter.export(project: imported, mediaURLs: [asset.id: movieSource, audio.id: wav],
            format: .h264MP4, to: avOutput, audioMode: .highQualityStereo,
            progress: { _ in }, preserveHDR: false, webOptimized: true)
        let av = AVURLAsset(url: avOutput)
        let videos = try await av.loadTracks(withMediaType: .video)
        let audios = try await av.loadTracks(withMediaType: .audio)
        let videoDescription = try await videos[0].load(.formatDescriptions)[0]
        let audioDescription = try await audios[0].load(.formatDescriptions)[0]
        precondition(CMFormatDescriptionGetMediaSubType(videoDescription) == kCMVideoCodecType_H264)
        precondition(CMFormatDescriptionGetMediaSubType(audioDescription) == kAudioFormatMPEG4AAC)
        let bytes = try Data(contentsOf: avOutput)
        precondition(bytes.range(of: Data("moov".utf8))!.lowerBound < bytes.range(of: Data("mdat".utf8))!.lowerBound)
        print("Web H.264/AAC codecs and fast-start movie layout passed")
        let player = ProjectPlayerViewModel()
        player.prepare(project: decoded, mediaURLs: [:])
        for _ in 0..<300 where !player.canControlPlayback { try await Task.sleep(for: .milliseconds(50)) }
        precondition(player.canControlPlayback)
        let item = player.player.currentItem
        player.player.play()
        try await Task.sleep(for: .milliseconds(150))
        let controller = ProjectController(document: ProjectDocument(project: decoded))
        controller.installProjectPlayer(player)
        let recording = UUID()
        InterfaceSounds.shared.capture(recording, active: true)
        controller.createMarker(at: player.precisePlayhead)
        InterfaceSounds.shared.capture(recording, active: false)
        precondition(ProjectPreviewInput(controller.project) == ProjectPreviewInput(decoded))
        precondition(player.player.currentItem === item && player.player.rate == 1)
        player.player.pause()
        print("Marker navigation update preserved playing item and rate")
    }
}
