import AVFoundation
import Foundation
import Darwin
import UniformTypeIdentifiers
@testable import Trimato

/// Exercises production exporters without launching Trimato or opening windows.
@main struct OutputReliabilityCheck {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw NSError(domain: "OutputReliability", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func range(_ start: Double, _ duration: Double) -> SourceSegment {
        SourceSegment(sourceRange: ProjectTimeRange(start: ProjectTime(seconds: start), duration: ProjectTime(seconds: duration)))
    }
    static func measure(_ url: URL) async throws -> (loudness: Double, peak: Double) {
        let result = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-hide_banner", "-nostdin", "-i", url.path,
            "-map", "0:a:0", "-af", "loudnorm=print_format=json", "-f", "null", "-"])
        let start = result.standardError.range(of: "{", options: .backwards)!.lowerBound
        let end = result.standardError[start...].firstIndex(of: "}")!
        let data = Data(result.standardError[start...end].utf8)
        let values = try JSONDecoder().decode([String: String].self, from: data)
        return (Double(values["input_i"]!)!, Double(values["input_tp"]!)!)
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reliability-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owned = try TemporaryMediaSession.directory(named: "TrimatoClipFilters")
        let initialFiles = try FileManager.default.contentsOfDirectory(atPath: owned.path).sorted()
        let source = directory.appendingPathComponent("long.wav")
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i",
            "aevalsrc=if(lt(t\\,8)\\,0.02\\,0.7)*sin(2*PI*440*t):s=48000:d=120", "-c:a", "pcm_f32le", source.path])
        let segments = [range(1, 2), range(5, 2)]
        var match = ClipFilter(kind: .matchLoudness)
        match.values = ["target": -20, "peak": -3]
        let start = Date()
        let output = try await ClipFilterRenderer.render(source: source, filters: [match], audio: true,
            duration: 120, segments: segments)
        defer { try? FileManager.default.removeItem(at: output) }
        let report = try await FFmpegMediaProbe.inspect(url: output)
        let levels = try await measure(output)
        try require(abs(report.duration - 4) < 0.02, "Matched edit lost its duration")
        try require(abs(levels.loudness + 20) < 0.5, "Discarded loud material affected matching: \(levels)")
        try require(levels.peak <= -2.8, "Matched edit exceeded peak ceiling")
        print("Retained edit from 120-second source: \(Date().timeIntervalSince(start)) seconds; \(levels.loudness) LUFS, \(levels.peak) dBTP")

        for (name, signal) in [("silence", "0"), ("peaks", "if(lt(t\\,0.005)\\,0.9\\,0.001)*sin(2*PI*1000*t)")] {
            let fixture = directory.appendingPathComponent(name + ".wav")
            _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i",
                "aevalsrc=\(signal):s=48000:d=4", "-c:a", "pcm_f32le", fixture.path])
            var constrained = match; constrained.values = ["target": -10, "peak": -6]
            let result = try await ClipFilterRenderer.render(source: fixture, filters: [constrained], audio: true, duration: 4)
            defer { try? FileManager.default.removeItem(at: result) }
            let measured = try await measure(result)
            if name == "silence" { try require(measured.peak == -.infinity, "Matching added sound to silence") }
            else {
                try require(abs(measured.peak + 6) < 0.2, "Matching ignored the true-peak ceiling: \(measured)")
                try require(measured.loudness < -11, "Matching exceeded headroom to force the loudness target")
            }
        }
        print("Silence and peak-constrained loudness matching passed")

        var echo = ClipFilter(kind: .echo); echo.values = ["delay": 100, "amount": 60]
        var limiter = ClipFilter(kind: .limitPeaks); limiter.values["ceiling"] = -6
        let withEffects = try await ClipFilterRenderer.render(source: source, filters: [match, echo, limiter], audio: true,
            duration: 120, segments: segments)
        defer { try? FileManager.default.removeItem(at: withEffects) }
        let effectLevels = try await measure(withEffects)
        try require(effectLevels.peak <= -5.8, "Effects escaped the final clip limiter")
        let effectReport = try await FFmpegMediaProbe.inspect(url: withEffects)
        try require(abs(effectReport.duration - 4) < 0.02, "Effects shifted the edit")

        var project = TrimatoProject(name: "Output reliability")
        let record = MediaAssetRecord(name: "Voice", originalPath: source.path, duration: ProjectTime(seconds: 120),
            hasAudio: true, sourceEdit: segments)
        let clipID = project.putRecording(record, at: .zero)
        try project.setClipEffects(id: clipID, audio: .neutral, filters: [match])
        let (prepared, urls, temporary) = try await ClipFilterRenderer.prepare(project: project, urls: [record.id: source])
        defer { for url in temporary { try? FileManager.default.removeItem(at: url) } }
        let clip = prepared.tracks.flatMap(\.clips).first { $0.id == clipID }!
        try require(clip.segments == segments, "Source timing or transition handles changed")
        try require(project.tracks.flatMap(\.clips).first { $0.id == clipID }!.segments == segments, "Original project changed")
        let projectEdit = try await ClipFilterRenderer.render(source: urls[clip.assetID]!, filters: [], audio: true,
            duration: 4, segments: segments)
        defer { try? FileManager.default.removeItem(at: projectEdit) }
        let preparedReport = try await FFmpegMediaProbe.inspect(url: urls[clip.assetID]!)
        try require(abs(preparedReport.duration - 120) < 0.02, "Matching removed transition handles")
        let transition = try await FFmpegTimelineEffectRenderer.renderAudioTransition(
            leadingURL: urls[clip.assetID]!, trailingURL: urls[clip.assetID]!, leadingClip: clip, trailingClip: clip,
            type: .crossFade, duration: ProjectTime(seconds: 1))
        defer { try? FileManager.default.removeItem(at: transition) }
        let transitionLevels = try await measure(transition)
        try require(transitionLevels.peak.isFinite && transitionLevels.peak < 0, "Matched crossfade has invalid output")
        try await ExportOutputValidator.validate(transition, duration: 1, video: false, audio: true)
        let projectLevels = try await measure(projectEdit)
        try require(abs(projectLevels.loudness - levels.loudness) < 0.1, "Preview and project loudness differ")

        for format: ExportFormat in [.wav24, .m4aAppleLossless, .flac, .m4a] {
            let destination = directory.appendingPathComponent("finished." + format.fileExtension)
            try Data("previous output".utf8).write(to: destination)
            var completed = false
            try await ProjectExporter.export(project: project, mediaURLs: [record.id: source],
                timeRange: ProjectTimeRange(start: ProjectTime(seconds: 0.5), duration: ProjectTime(seconds: 2)),
                format: format, to: destination, progress: { value in
                    if value == 1 {
                        completed = (try? Data(contentsOf: destination)) != Data("previous output".utf8)
                    }
                })
            try require(completed, "Completion preceded committing \(format)")
            try await ExportOutputValidator.validate(destination, duration: 2, video: false, audio: true)
            print("Selected-range project export passed: \(format)")
        }
        let singleMix = directory.appendingPathComponent("single-mix.wav")
        try await ProjectExporter.export(project: project, mediaURLs: [record.id: source],
            format: .wav24, to: singleMix, progress: { _ in })
        let singleMixLevels = try await measure(singleMix)
        // Two overlapping tracks and master gain must survive export as the user's mix.
        var second = record; second.id = UUID(); second.name = "Second voice"
        let secondID = project.putRecording(second, at: .zero)
        try project.setClipEffects(id: secondID, audio: .neutral, filters: [match])
        project.masterVolumeDB = -6
        let mixed = directory.appendingPathComponent("mix.wav")
        try await ProjectExporter.export(project: project, mediaURLs: [record.id: source, second.id: source],
            format: .wav24, to: mixed, progress: { _ in })
        let mixedLevels = try await measure(mixed)
        try require(mixedLevels.peak.isFinite && mixedLevels.peak < 0, "Mix clipped")
        try require(abs(mixedLevels.loudness - singleMixLevels.loudness) < 1, "Overlap/master gain was altered: \(mixedLevels)")
        print("Overlapping tracks with -6 dB master: \(mixedLevels.loudness) LUFS, \(mixedLevels.peak) dBTP")

        let invalid = directory.appendingPathComponent("invalid.wav")
        try Data("incomplete".utf8).write(to: invalid)
        do { try await ExportOutputValidator.validate(invalid, duration: 2, video: false, audio: true)
            throw NSError(domain: "Unexpected validation success", code: 1)
        } catch let error as NSError { try require(error.domain != "Unexpected validation success", "Corrupt output accepted") }
        do { try await ExportOutputValidator.validate(output, duration: 10, video: false, audio: true)
            throw NSError(domain: "Unexpected validation success", code: 1)
        } catch let error as NSError { try require(error.domain != "Unexpected validation success", "Truncated output accepted") }
        let cancelled = directory.appendingPathComponent("cancelled.wav")
        try Data("saved".utf8).write(to: cancelled)
        let cancelAtFinish = Task { @MainActor in
            try await AudioOnlyExporter.export(asset: AVURLAsset(url: output), audioMix: nil, timeRange: nil,
                format: .wav24, to: cancelled, progress: { value in
                    if value > 0.95 { withUnsafeCurrentTask { $0?.cancel() } }
                })
        }
        do { try await cancelAtFinish.value; throw NSError(domain: "Cancellation ignored", code: 1) }
        catch is CancellationError { }
        try require(try Data(contentsOf: cancelled) == Data("saved".utf8), "Cancellation replaced saved output")
        print("Corrupt/truncated output rejection and cancellation near finalization passed")

        let folder = directory.appendingPathComponent("New project")
        let saved = try ProjectDocument.writeNewProject(project, toFolderAt: folder)
        let restored = try ProjectDocument.decodeProject(from: FileWrapper(url: saved))
        try require(restored.tracks == project.tracks, "Project failed save/reopen")
        do { _ = try ProjectDocument.writeNewProject(TrimatoProject(), toFolderAt: folder)
            throw NSError(domain: "Existing project replaced", code: 1)
        } catch let error as NSError { try require(error.domain != "Existing project replaced", "Existing project replaced") }
        let model = ProjectDocument(project: restored)
        model.project.name = "Unsaved change"
        do { _ = try ProjectDocument.writeNewProject(model.project, toFolderAt: invalid.appendingPathComponent("Impossible")) }
        catch { }
        try require(model.hasUnsavedChanges, "Failed write cleared unsaved changes")
        try require(try ProjectDocument.decodeProject(from: FileWrapper(url: saved)).tracks == restored.tracks,
                    "Failed write changed the saved project")
        print("Project save/reopen and failure preservation passed")

        let stereoBytes = try ProjectRenderMediaManager.estimatedBytes(duration: 10, width: nil, height: nil,
            hasVideo: false, sampleRate: 96000, channels: 2)
        try require(stereoBytes >= 10 * 96000 * 2 * 4, "Storage estimate undercounts stereo PCM")
        do { _ = try ProjectRenderMediaManager.estimatedBytes(duration: .infinity, width: nil, height: nil, hasVideo: false)
            throw NSError(domain: "Invalid estimate accepted", code: 1)
        } catch let error as NSError { try require(error.domain != "Invalid estimate accepted", "Invalid estimate accepted") }

        let normalVideo = try ProjectRenderMediaManager.estimatedBytes(duration: 10, width: 1920, height: 1080, hasVideo: true)
        let fastVideo = try ProjectRenderMediaManager.estimatedBytes(duration: 10, width: 1920, height: 1080,
            hasVideo: true, frameRate: 120)
        try require(fastVideo > normalVideo * 3, "Storage estimate ignored high frame rate")
        let movie = directory.appendingPathComponent("source.mov")
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i",
            "color=c=blue:s=160x90:r=30:d=2", "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
            "-c:v", "prores_ks", "-profile:v", "0", "-c:a", "pcm_s16le", "-shortest", movie.path])
        for format: ExportFormat in [.h264MP4, .hevcMovie, .proRes422] {
            let destination = directory.appendingPathComponent("movie-\(format)." + format.fileExtension)
            try await ClipExporter.export(asset: AVURLAsset(url: movie), sourceRanges: [range(0.5, 1).sourceRange.cmTimeRange],
                sourceContentType: nil, format: format, to: destination, preserveSpatialAudio: false, progress: { _ in })
            try await ExportOutputValidator.validate(destination, duration: 1, video: true, audio: true)
            print("Standalone video export passed: \(format)")
        }
        let passthrough = directory.appendingPathComponent("passthrough.mov")
        try await ClipExporter.export(asset: AVURLAsset(url: movie), timeRange: range(0.5, 1).sourceRange.cmTimeRange,
            sourceContentType: .quickTimeMovie, to: passthrough)
        try await ExportOutputValidator.validate(passthrough, duration: 1, video: true, audio: true)
        let ffmpeg = directory.appendingPathComponent("ffmpeg.mp4")
        try await FFmpegClipExporter.export(sourceURL: movie, sourceRanges: [range(0.5, 1).sourceRange.cmTimeRange],
            hasAudio: true, format: .h264MP4, to: ffmpeg, progress: { _ in })
        print("Native passthrough and FFmpeg video export passed")
        var videoProject = TrimatoProject(name: "Video output")
        let videoRecord = MediaAssetRecord(name: "Movie", originalPath: movie.path,
            duration: ProjectTime(seconds: 2), naturalWidth: 160, naturalHeight: 90, frameRate: 30,
            hasAudio: true, sourceEdit: [range(0, 2)])
        videoProject.media = [videoRecord]
        _ = try videoProject.append(asset: videoRecord)
        let projectMovie = directory.appendingPathComponent("project.mp4")
        try await ProjectExporter.export(project: videoProject, mediaURLs: [videoRecord.id: movie],
            format: .h264MP4, to: projectMovie, audioMode: .highQualityStereo, progress: { _ in })
        try await ExportOutputValidator.validate(projectMovie, duration: 2, video: true, audio: true)
        print("Full-project video export passed")

        if CommandLine.arguments.count > 1 {
            let spatialSource = URL(fileURLWithPath: CommandLine.arguments[1])
            let originalHash = try MediaFileTransfer.checksum(spatialSource)
            let original = AVURLAsset(url: spatialSource)
            guard let plan = try await SpatialAudioPlan.clip(asset: original, ranges: [range(0.5, 1).sourceRange.cmTimeRange]) else {
                throw NSError(domain: "Spatial fixture has no spatial audio", code: 1)
            }
            let spatialOutput = directory.appendingPathComponent("spatial.mov")
            try await plan.export(includeSourceVideo: true, to: spatialOutput, progress: { _ in })
            let preserved = try await SpatialAudioPlan.detect(in: AVURLAsset(url: spatialOutput))
            try require(preserved, "Spatial alternate audio was not preserved")
            let hdrOutput = try await HDRVideoRenderer.render(source: spatialOutput,
                filters: [ClipFilter(kind: .brightnessContrast)])
            defer { try? FileManager.default.removeItem(at: hdrOutput) }
            let hdr = try await FFmpegMediaProbe.inspect(url: hdrOutput)
            try require(hdr.isHDR && abs(hdr.duration - 1) < 0.15, "HDR filter output lost tags or duration")
            try require(try MediaFileTransfer.checksum(spatialSource) == originalHash, "Spatial fixture changed")
            print("Spatial selected-range preservation and HDR filter export passed; source checksum unchanged")
        }
        for file in temporary + [output, withEffects, projectEdit] { try FileManager.default.removeItem(at: file) }
        try require(try FileManager.default.contentsOfDirectory(atPath: owned.path).sorted() == initialFiles,
            "Finished filter operations left temporary media")
        print("Temporary filter cleanup passed")
        print("Output reliability checks passed")
    }
}
