import AppKit
import AVFoundation
import Foundation
@testable import Trimato

@main struct FadeAudioCheck {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fade-audio-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("tone.mov")
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i", "color=c=red:s=160x120:r=30", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "4", "-c:v", "prores_ks", "-c:a", "pcm_s16le", source.path])
        let movie = MediaAssetRecord(name: "Movie", originalPath: source.path, duration: ProjectTime(seconds: 4),
            naturalWidth: 160, naturalHeight: 120, frameRate: 30, hasAudio: true,
            sourceEdit: [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 4)))])
        var black = GeneratorDefinition()
        black.width = 160; black.height = 120; black.duration = ProjectTime(seconds: 1)
        let blackAsset = black.assetRecord()
        var project = TrimatoProject()
        project.media = [movie, blackAsset]
        let movieID = try project.append(asset: movie)
        _ = try project.insert(asset: blackAsset, at: .zero)
        let videoTrack = project.tracks.first { $0.role == .primaryVideo }!
        let audioTrack = project.tracks.first { $0.role == .primaryAudio }!
        let video = project.timelineClip(id: movieID)!
        let audio = project.timelineClip(id: video.linkedClipID!)!
        precondition(video.timelineStart.seconds == 1 && audio.timelineStart == video.timelineStart)
        let player = ProjectPlayerViewModel()
        player.prepare(project: project, mediaURLs: [movie.id: source])
        for _ in 0..<300 where !player.canControlPlayback { try await Task.sleep(for: .milliseconds(50)) }
        precondition(player.canControlPlayback)
        player.updateMix(project: project)
        let controller = ProjectController(document: ProjectDocument(project: project))
        controller.installProjectPlayer(player)
        let liveRequest = TransitionRequest(trackID: videoTrack.id, clipID: movieID, mode: .quickFade,
            fadeOutClipID: videoTrack.sortedClips.first!.id)
        let liveFades = liveRequest.makeFades(in: project, fadeInDuration: ProjectTime(seconds: 1),
            fadeOutDuration: nil, includeAudio: true)!
        try await controller.applyTransitionsFromEditor(liveFades)
        var liveStart: Float = 0, liveEnd: Float = 0
        var liveRange = CMTimeRange.zero
        let liveInput = player.player.currentItem!.audioMix!.inputParameters.first!
        precondition(liveInput.getVolumeRamp(for: ProjectTime(seconds: 1.1).cmTime,
            startVolume: &liveStart, endVolume: &liveEnd, timeRange: &liveRange))
        print("Applied live preview ramp", liveStart, liveEnd, liveRange.start.seconds, liveRange.duration.seconds)
        precondition(liveStart == 0 && liveEnd == 1 && liveRange.start.seconds == 1 && liveRange.duration.seconds == 1,
            "Apply Fade replaced the candidate fade with the previous project envelope")
        for intro in [true, false] {
            var faded = project
            let request = TransitionRequest(trackID: videoTrack.id, clipID: movieID, mode: .quickFade,
                fadeOutClipID: videoTrack.sortedClips.first!.id)
            // Outro test targets the movie, as a selected-clip fade would.
            let target = intro ? request : TransitionRequest(trackID: videoTrack.id, clipID: movieID, mode: .quickFade)
            let fades = target.makeFades(in: faded, fadeInDuration: intro ? ProjectTime(seconds: 1) : nil,
                fadeOutDuration: intro ? nil : ProjectTime(seconds: 1), includeAudio: true)!
            _ = try faded.addTransitionBatch(fades)
            precondition(faded.transitions.contains { $0.trackID == audioTrack.id && $0.kind == .audio(.fade) })
            let result = try await ProjectCompositionBuilder.build(project: faded, mediaURLs: [movie.id: source], purpose: .preview, audioMode: .highQualityStereo)
            let parameters = result.audioMix!.inputParameters.first!
            var start: Float = 0, end: Float = 0
            var range = CMTimeRange.zero
            let rampTime = ProjectTime(seconds: intro ? 1.1 : 4.1)
            precondition(parameters.getVolumeRamp(for: rampTime.cmTime, startVolume: &start, endVolume: &end, timeRange: &range))
            print("Preview ramp", intro ? "intro" : "outro", start, end, range.start.seconds, range.duration.seconds)
            for format in [ExportFormat.wav24, .h264MP4] {
                let output = directory.appendingPathComponent("\(intro)-\(format.rawValue)").appendingPathExtension(format.fileExtension)
                try await ProjectExporter.export(project: faded, mediaURLs: [movie.id: source], format: format,
                    to: output, audioMode: .highQualityStereo, progress: { _ in }, preserveHDR: false)
                let raw = directory.appendingPathComponent("samples.f32")
                _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-nostdin", "-y", "-i", output.path,
                    "-map", "0:a:0", "-ac", "1", "-ar", "48000", "-f", "f32le", raw.path])
                let data = try Data(contentsOf: raw)
                let samples = data.withUnsafeBytes { bytes in stride(from: 0, to: bytes.count, by: 4).map {
                    Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
                } }
                func power(_ from: Double, _ to: Double) -> Double {
                    let values = samples[Int(from * 48000)..<Int(to * 48000)]
                    return values.reduce(0) { $0 + Double($1 * $1) } / Double(values.count)
                }
                let quiet = power(intro ? 1.05 : 4.85, intro ? 1.15 : 4.95)
                let loud = power(2.2, 2.3)
                print("Export", format.rawValue, intro ? "intro" : "outro", "quiet/loud power", quiet / loud)
                precondition(quiet / loud < 0.04, "Audio fade was not applied to exported samples")
            }
        }
        print("PASS: black-before-video alignment, intro-only and outro-only linked audio fades, preview ramps, WAV and MP4 sound")
    }
}
