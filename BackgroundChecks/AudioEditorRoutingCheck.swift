import AppKit
import AVFoundation
@testable import Trimato

@main struct AudioEditorRoutingCheck {
    @MainActor static func main() async throws {
        precondition(NSApp == nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("movie.mov")
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-nostdin", "-y",
            "-f", "lavfi", "-i", "color=c=black:s=32x32:r=30:d=2", "-f", "lavfi", "-i",
            "anullsrc=r=48000:cl=stereo", "-t", "2", "-c:v", "mpeg4", "-c:a", "aac", url.path])
        let range = SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 2)))
        let movie = MediaAssetRecord(name: "Movie", originalPath: url.path, duration: ProjectTime(seconds: 2),
            naturalWidth: 32, naturalHeight: 32, frameRate: 30, hasAudio: true, sourceEdit: [range])
        var project = TrimatoProject()
        project.media = [movie]
        let audio = TimelineClip(assetID: movie.id, name: "Sound", segments: [range])
        let extra = TimelineClip(assetID: movie.id, name: "Other sound", segments: [range])
        let video = TimelineClip(assetID: movie.id, name: "Picture", segments: [range])
        project.tracks = [TimelineTrack(name: "Primary Audio", kind: .audio, role: .primaryAudio, clips: [audio]),
            TimelineTrack(name: "Other audio", kind: .audio, role: .additional, clips: [extra]),
            TimelineTrack(name: "Primary Video", kind: .video, role: .primaryVideo, clips: [video])]
        let controller = ProjectController(document: ProjectDocument(project: project))
        for (selection, expected) in [(EditorSelection.timelineClip(audio.id), false), (.timelineClip(extra.id), false),
                                      (.timelineClip(video.id), true), (.asset(movie.id), true)] {
            let context = ClipPlacementCommandContext(controller: controller, editSelection: selection, segments: [range])
            precondition(context.editsVideo == expected)
            precondition((context.audioSettings != nil) == !expected)
        }
        let source = MediaSource.native(url: url, asset: AVURLAsset(url: url), contentType: .quickTimeMovie,
            mode: .nativePassthrough, hasVideo: true, hasAudio: true)
        let sound = try await source.audioEditingSource()
        precondition(!sound.hasVideo && sound.hasAudio && sound.frameTimestamps.isEmpty)
        precondition(sound.mode != .nativePassthrough)
        let audioTracks = try await sound.playbackAsset.loadTracks(withMediaType: .audio)
        let videoTracks = try await sound.playbackAsset.loadTracks(withMediaType: .video)
        precondition(audioTracks.count == 1 && videoTracks.isEmpty)
        let model = VideoPlayerViewModel()
        model.player.isMuted = true
        var completions = 0
        model.load(url: url, preparedSource: source, audioOnly: true, loaded: {
            fatalError("Superseded load completed")
        })
        model.load(url: url, sourceSegments: [range], preparedSource: source, audioOnly: true, loaded: {
            precondition(model.hasMedia && !model.isLoadingMedia && !model.audioPreviewSegments.isEmpty)
            completions += 1
        })
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while model.isLoadingMedia {
            precondition(ContinuousClock.now < deadline, "Audio editor load timed out")
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(completions == 1)
        precondition(model.hasMedia && !model.hasVideo, model.mediaOpenErrorMessage ?? "Incorrect editor mode")
        let playerVideo = try await model.player.currentItem!.asset.loadTracks(withMediaType: .video)
        precondition(playerVideo.isEmpty)
        model.load(url: url, preparedSource: source, audioOnly: true, loaded: {
            fatalError("Cancelled load completed")
        })
        model.cancelMediaLoad()
        try await Task.sleep(for: .milliseconds(100))
        model.closeMedia()
        let cut = try await EditedCompositionBuilder.playbackAsset(asset: sound.playbackAsset,
            sourceRanges: [CMTimeRange(start: CMTime(seconds: 0.5, preferredTimescale: 600),
                                       duration: CMTime(seconds: 1, preferredTimescale: 600))], includeVideo: false)
        let cutVideo = try await cut.loadTracks(withMediaType: .video)
        let duration = try await cut.load(.duration)
        precondition(cutVideo.isEmpty && abs(duration.seconds - 1) < 0.001)
        let originalVideo = try await source.playbackAsset.loadTracks(withMediaType: .video)
        precondition(originalVideo.count == 1)
        let output = directory.appendingPathComponent("audio.m4a")
        let format = ExportFormat.projectFormats.first { $0.isAudioOnly }!
        try await FFmpegClipExporter.export(sourceURL: sound.originalURL,
            sourceRanges: [CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600))],
            hasAudio: true, format: format, to: output, audioMode: .highQualityStereo) { _ in }
        let exportedVideo = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        let exportedAudio = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
        precondition(exportedVideo.isEmpty && !exportedAudio.isEmpty)
        let ordinary = MediaSource.native(url: output, asset: AVURLAsset(url: output), contentType: .mpeg4Audio,
            mode: .nativePassthrough, hasVideo: false, hasAudio: true)
        let unchanged = try await ordinary.audioEditingSource()
        precondition(!unchanged.hasVideo && unchanged.mode == .nativePassthrough)
        print("PASS: audio track routing, source/video routing, audio-only playback, subsequent edits, and audio export")
    }
}
