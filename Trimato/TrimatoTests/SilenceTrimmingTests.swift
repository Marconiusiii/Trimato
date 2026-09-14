import AVFoundation
import Combine
import Foundation
import Testing
@testable import Trimato

@Suite("Silence trimming", .serialized)
@MainActor struct SilenceTrimmingTests {
    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600_000) }

    @Test func removesDetectedPausesAndPreservesSourceRanges() throws {
        let timeline = ClipEditTimeline(sourceDuration: time(10))
        let plan = try ClipSilenceTrimmer.plan(diagnostics: "silence_start: 2\nsilence_end: 4 | silence_duration: 2\nsilence_start: 8\n",
            timeline: timeline, selection: CMTimeRange(start: .zero, duration: time(10)), retainedPause: 0.2, frameRate: 0)
        #expect(plan.removedCount == 2)
        #expect(abs(plan.removedSeconds - 3.6) < 0.00001)
        #expect(plan.sourceRanges.count == 3)
        #expect(abs(plan.sourceRanges[1].start.seconds - 3.9) < 0.00001)
    }

    @Test func editedSelectionMapsBackAcrossExistingCuts() throws {
        let timeline = ClipEditTimeline(sourceRanges: [CMTimeRange(start: time(5), duration: time(3)),
            CMTimeRange(start: time(12), duration: time(3))])
        let plan = try ClipSilenceTrimmer.plan(diagnostics: "silence_start: 1\nsilence_end: 3",
            timeline: timeline, selection: CMTimeRange(start: time(1), duration: time(4)), retainedPause: 0, frameRate: 0)
        #expect(abs(plan.removedSeconds - 2) < 0.00001)
        #expect(plan.sourceRanges.map { $0.duration.seconds }.reduce(0, +) == 4)
        #expect(plan.sourceRanges.contains { $0.start == time(13) })
        #expect(plan.remap(time(1)) == time(1))
        #expect(plan.remap(time(5)) == time(3))
    }

    @Test func silentSelectionIsRejectedAndNoSilenceIsUnchanged() throws {
        let timeline = ClipEditTimeline(sourceDuration: time(5))
        let selection = CMTimeRange(start: .zero, duration: time(5))
        #expect(throws: SilenceTrimError.self) {
            try ClipSilenceTrimmer.plan(diagnostics: "silence_start: 0\nsilence_end: 5", timeline: timeline,
                selection: selection, retainedPause: 0.1, frameRate: 0)
        }
        let unchanged = try ClipSilenceTrimmer.plan(diagnostics: "", timeline: timeline,
            selection: selection, retainedPause: 0.1, frameRate: 0)
        #expect(unchanged.sourceRanges == timeline.sourceRanges)
        #expect(unchanged.removedCount == 0)
    }

    @Test func videoCutsStayInsideDetectedSilenceOnFrameBoundaries() throws {
        let timeline = ClipEditTimeline(sourceDuration: time(5))
        let plan = try ClipSilenceTrimmer.plan(diagnostics: "silence_start: 1.013\nsilence_end: 2.997", timeline: timeline,
            selection: CMTimeRange(start: .zero, duration: time(5)), retainedPause: 0.1, frameRate: 30)
        #expect(abs(plan.sourceRanges[0].end.seconds * 30 - (plan.sourceRanges[0].end.seconds * 30).rounded()) < 0.0001)
        #expect(plan.sourceRanges[0].end.seconds >= 1.063)
        #expect(plan.sourceRanges[1].start.seconds <= 2.947)
    }

    @Test func playbackTicksDoNotInvalidateTheEditorModel() {
        let model = VideoPlayerViewModel()
        var changes = 0
        let observer = model.objectWillChange.sink { changes += 1 }
        for index in 0..<54_000 {
            model.currentTime = Double(index) / 30
            model.currentFrame = index
            model.displayTimecode = "\(index)"
        }
        #expect(changes == 0)
        #expect(model.currentFrame == 53_999)
        withExtendedLifetime(observer) {}
    }

    @Test func longEditedFrameIndexPreservesExactFrameTimes() {
        let timestamps = (0..<54_000).map { CMTime(value: Int64($0), timescale: 30) }
        let ranges = (0..<900).map { CMTimeRange(start: time(Double($0 * 2)), duration: time(1)) }
        let result = EditedCompositionBuilder.editedFrameTimestamps(sourceTimestamps: timestamps, sourceRanges: ranges)
        #expect(result.count == 27_000)
        #expect(result.last == CMTime(value: 26_999, timescale: 30))
    }

    @Test func detectsRealAudioAndVideoPausesAndExportsTheRetainedEdit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for video in [false, true] {
            let input = directory.appendingPathComponent(video ? "source.mp4" : "source.wav")
            var args = ["-hide_banner", "-nostdin", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=1:sample_rate=48000",
                "-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono:d=2", "-f", "lavfi", "-i", "sine=frequency=660:duration=1:sample_rate=48000"]
            if video { args += ["-f", "lavfi", "-i", "color=c=blue:s=160x90:r=30:d=4"] }
            args += ["-filter_complex", "[0:a][1:a][2:a]concat=n=3:v=0:a=1[a]", "-map", "[a]"]
            if video { args += ["-map", "3:v", "-c:v", "h264_videotoolbox", "-c:a", "aac"] }
            else { args += ["-c:a", "pcm_s16le"] }
            args += [input.path]
            _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: args)
            let original = try Data(contentsOf: input)
            let timeline = ClipEditTimeline(sourceDuration: time(4))
            let plan = try await ClipSilenceTrimmer.analyze(url: input, timeline: timeline,
                selection: CMTimeRange(start: .zero, duration: time(4)),
                settings: SilenceTrimSettings(), frameRate: video ? 30 : 0)
            #expect(plan.removedCount == 1)
            #expect(abs(plan.removedSeconds - 1.85) < 0.08)
            let asset = AVURLAsset(url: input)
            let preview = try await EditedCompositionBuilder.playbackAsset(asset: asset, sourceRanges: plan.sourceRanges)
            let duration = try await preview.load(.duration).seconds
            #expect(abs(duration - (4 - plan.removedSeconds)) < 0.001)
            let output = directory.appendingPathComponent(video ? "result.mp4" : "result.wav")
            try await ClipExporter.export(asset: asset, sourceRanges: plan.sourceRanges,
                sourceContentType: video ? .mpeg4Movie : .wav, format: video ? .h264MP4 : .wav,
                to: output, preserveSpatialAudio: false, progress: { _ in })
            let exported = AVURLAsset(url: output)
            #expect(abs(try await exported.load(.duration).seconds - duration) < 0.1)
            #expect(try Data(contentsOf: input) == original)
            let record = MediaAssetRecord(name: "Silence edit", originalPath: input.path,
                duration: ProjectTime(seconds: 4), naturalWidth: video ? 160 : nil,
                naturalHeight: video ? 90 : nil, frameRate: video ? 30 : nil, hasAudio: true, sourceEdit: [])
            var project = TrimatoProject()
            project.media = [record]
            let segments = plan.sourceRanges.map { SourceSegment(sourceRange: ProjectTimeRange($0)) }
            let clipID = try project.append(asset: record, segments: segments)
            let reopened = try JSONDecoder().decode(TrimatoProject.self, from: JSONEncoder().encode(project))
            #expect(reopened.timelineClip(id: clipID)?.segments == segments)
            let model = VideoPlayerViewModel()
            model.load(url: input)
            for _ in 0..<1000 where model.isLoadingMedia || !model.hasMedia {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(model.canTrimSilences)
            let (_, loadedTimeline, _, loadedAsset) = try model.silenceTrimInput(markedOnly: false)
            let readyPreview = try await EditedCompositionBuilder.playbackAsset(asset: loadedAsset, sourceRanges: plan.sourceRanges)
            let undo = UndoManager()
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            try model.applySilenceTrim(plan, previewAsset: readyPreview, expectedTimeline: loadedTimeline, undoManager: undo)
            undo.endUndoGrouping()
            #expect(abs(model.duration - duration) < 0.001)
            #expect(undo.canUndo)
            undo.undo()
            #expect(abs(model.duration - loadedTimeline.duration.seconds) < 0.001)
            #expect(undo.canRedo)
            undo.redo()
            #expect(abs(model.duration - duration) < 0.001)
            model.closeMedia()
        }
    }

    @Test func silenceDetectionRequiresAllStereoChannelsToBeQuiet() async throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: input) }
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-hide_banner", "-nostdin", "-y", "-f", "lavfi", "-i",
            "aevalsrc=0|0.2*sin(2*PI*440*t):s=48000:d=2", "-c:a", "pcm_s16le", input.path])
        let timeline = ClipEditTimeline(sourceDuration: time(2))
        let plan = try await ClipSilenceTrimmer.analyze(url: input, timeline: timeline,
            selection: CMTimeRange(start: .zero, duration: time(2)), settings: SilenceTrimSettings(), frameRate: 0)
        #expect(plan.removedCount == 0)
    }

    @Test func cancelledAnalysisAndInvalidSettingsDoNotProduceAnEdit() async throws {
        let timeline = ClipEditTimeline(sourceDuration: time(4))
        let url = URL(fileURLWithPath: "/unused-silence-test-input.wav")
        let job = Task {
            try await ClipSilenceTrimmer.analyze(url: url, timeline: timeline,
                selection: CMTimeRange(start: .zero, duration: timeline.duration), settings: SilenceTrimSettings(), frameRate: 0)
        }
        job.cancel()
        do {
            _ = try await job.value
            Issue.record("Cancelled analysis returned an edit")
        } catch is CancellationError {} catch {
            Issue.record("Expected cancellation, got \(error)")
        }
        var settings = SilenceTrimSettings()
        settings.retainedPause = settings.minimumPause
        do {
            _ = try await ClipSilenceTrimmer.analyze(url: url, timeline: timeline,
                selection: CMTimeRange(start: .zero, duration: timeline.duration), settings: settings, frameRate: 0)
            Issue.record("Invalid pause settings were accepted")
        } catch SilenceTrimError.invalidSettings {} catch {
            Issue.record("Expected settings validation, got \(error)")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRIMATO_LONG_PLAYBACK_FILE"] != nil))
    func longMediaPlaybackKeepsEditorInvalidationsBounded() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["TRIMATO_LONG_PLAYBACK_FILE"])
        let model = VideoPlayerViewModel()
        model.player.volume = 0
        model.load(url: URL(fileURLWithPath: path))
        defer { model.closeMedia() }
        for _ in 0..<3000 where model.isLoadingMedia || !model.hasMedia {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.hasMedia && model.duration >= 1799)
        var editorChanges = 0
        let observer = model.objectWillChange.sink { editorChanges += 1 }
        model.togglePlayPause()
        try await Task.sleep(for: .seconds(5))
        #expect(model.currentTime > 1)
        #expect(editorChanges < 30, "Clock ticks must not invalidate the complete editor.")
        model.togglePlayPause()
        print("Long clip playback: \(editorChanges) editor model notifications, position \(model.currentTime) seconds")
        withExtendedLifetime(observer) {}
    }
}
