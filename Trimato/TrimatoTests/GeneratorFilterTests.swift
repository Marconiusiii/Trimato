import AVFoundation
import Foundation
import Testing
@testable import Trimato

@Suite(.serialized)
@MainActor
struct GeneratorFilterTests {
    @Test func successiveFilterPassesReportSeparatePartsOfOverallProgress() {
        var values: [Double] = []
        let first = ClipFilterRenderer.progress(in: 0...0.8) { values.append($0) }
        let second = ClipFilterRenderer.progress(in: 0.8...1) { values.append($0) }
        first?(0)
        first?(0.5)
        first?(1)
        second?(0)
        second?(0.5)
        second?(1)
        #expect(values == [0, 0.4, 0.8, 0.8, 0.9, 1])
    }

    private func definition(_ kind: GeneratorKind = .black) -> GeneratorDefinition {
        var value = GeneratorDefinition()
        value.kind = kind
        value.width = 64
        value.height = 48
        value.duration = ProjectTime(seconds: 0.5)
        value.frameRate = 24
        if kind == .text { value.textSettings.text = "Title" }
        return value
    }

    @Test(arguments: [24.0, 30.0, 30_000.0 / 1_001.0, 60_000.0 / 1_001.0])
    func durationUnitsConvertToUsableWholeFramesAndBack(frameRate: Double) {
        var project = TrimatoProject()
        project.format.frameRate = frameRate
        let controller = ProjectController(document: ProjectDocument(project: project))
        let session = GeneratorSession(controller: controller)
        #expect(session.durationUnit == .seconds)
        #expect(session.durationValue == 5)

        let expectedFrames = (5 * frameRate).rounded()
        session.setDurationUnit(.frames)
        #expect(session.durationValue == expectedFrames)
        #expect(session.durationValue.rounded() == session.durationValue)
        session.setDurationUnit(.frames)
        #expect(session.durationValue == expectedFrames)

        session.setDurationUnit(.seconds)
        #expect(abs(session.durationValue - expectedFrames / frameRate) < 0.000_001)
        session.setDurationUnit(.frames)
        #expect(session.durationValue == expectedFrames)
    }

    @Test func editedFrameCountConvertsBackToSeconds() {
        var project = TrimatoProject()
        project.format.frameRate = 24
        let controller = ProjectController(document: ProjectDocument(project: project))
        let session = GeneratorSession(controller: controller)
        session.durationValue = 1.25
        session.setDurationUnit(.frames)
        #expect(session.durationValue == 30)
        session.durationValue = 72
        session.setDurationUnit(.seconds)
        #expect(session.durationValue == 3)
    }

    @Test func shortPositiveDurationUsesOneFrameButZeroRemainsInvalid() {
        let controller = ProjectController(document: ProjectDocument(project: TrimatoProject()))
        let session = GeneratorSession(controller: controller)
        session.durationValue = 0.001
        session.setDurationUnit(.frames)
        #expect(session.durationValue == 1)
        session.setDurationUnit(.seconds)
        session.durationValue = 0
        session.setDurationUnit(.frames)
        #expect(session.durationValue == 0)
    }

    @Test func changingGeneratorTypeKeepsCompatibleDestinationAndDuration() {
        var project = TrimatoProject()
        let video = project.createTrack(kind: .video)
        let audio = project.createTrack(kind: .audio)
        let controller = ProjectController(document: ProjectDocument(project: project))
        let session = GeneratorSession(controller: controller)
        session.trackID = video
        session.durationValue = 2.5

        var previous = session.definition
        session.definition.kind = .gradient
        session.definitionChanged(from: previous)
        #expect(session.trackID == video)
        #expect(session.progress == nil)
        #expect(session.durationValue == 2.5)

        previous = session.definition
        session.definition.kind = .silence
        session.definitionChanged(from: previous)
        #expect(session.trackID == audio)
        #expect(session.durationValue == 2.5)
    }

    @Test func generatorPlacementIsAtomicAndAdvancesInsertionPlayhead() throws {
        let controller = ProjectController(document: ProjectDocument(project: TrimatoProject()))
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.installUndoManager(undo)
        let before = controller.project
        undo.beginUndoGrouping()
        try controller.placeGenerator(definition(), placement: .insert, at: .zero, trackID: nil, newTrackName: "Generated", expectedProject: before)
        undo.endUndoGrouping()
        #expect(controller.project.media.count == 1)
        #expect(controller.project.tracks.count == 1)
        #expect(controller.timelinePlayhead == ProjectTime(seconds: 0.5))
        let saved = try JSONDecoder().decode(TrimatoProject.self, from: JSONEncoder().encode(controller.project))
        #expect(saved.media[0].generator == definition())
        undo.undo()
        #expect(controller.project == before)
        undo.redo()
        #expect(controller.project.media.count == 1)
        let unchanged = controller.project
        #expect(throws: (any Error).self) {
            try controller.placeGenerator(definition(), placement: .insert, at: .zero, trackID: UUID(), newTrackName: "", expectedProject: unchanged)
        }
        #expect(controller.project == unchanged)
    }

    @Test func generatorNamesUseLettersAndMatchTimelineEntries() throws {
        let controller = ProjectController(document: ProjectDocument(project: TrimatoProject()))
        for _ in 0..<3 {
            try controller.placeGenerator(definition(), placement: .append, at: .zero,
                                          trackID: controller.project.tracks.first?.id,
                                          newTrackName: "Generated", expectedProject: controller.project)
        }
        #expect(controller.project.media.map(\.name) == ["Black", "Black A", "Black B"])
        #expect(controller.project.tracks.flatMap(\.clips).map(\.displayName) == ["Black", "Black A", "Black B"])
        let names = ["Black"] + (0..<26).map { "Black \(TimelineClip.letterLabel(for: $0))" }
        #expect(GeneratorSourceNaming.nextName(base: "Black", usedNames: names) == "Black AA")
    }

    @Test func olderGeneratorNamesNormalizeOnceAndPreserveCustomNames() throws {
        var project = TrimatoProject()
        let first = definition().assetRecord()
        let second = definition().assetRecord()
        var custom = definition().assetRecord()
        custom.name = "Custom backdrop"
        project.media = [first, second, custom]
        let firstID = try project.append(asset: first)
        let secondID = try project.append(asset: second)
        try project.renameTrackClip(id: firstID, to: "Opening")
        GeneratorSourceNaming.normalize(in: &project)
        #expect(project.media.map(\.name) == ["Black", "Black A", "Custom backdrop"])
        #expect(project.timelineClip(id: firstID)?.displayName == "Opening")
        #expect(project.timelineClip(id: secondID)?.displayName == "Black A")
        let before = project
        GeneratorSourceNaming.normalize(in: &project)
        #expect(project == before)
        let reopened = try JSONDecoder().decode(TrimatoProject.self, from: JSONEncoder().encode(project))
        let controller = ProjectController(document: ProjectDocument(project: reopened))
        #expect(controller.project == reopened)
    }

    @Test func updatingGeneratorKeepsNameAndDoesNotLeaveAnObsoleteSourceRow() throws {
        let controller = ProjectController(document: ProjectDocument(project: TrimatoProject()))
        try controller.placeGenerator(definition(), placement: .append, at: .zero, trackID: nil,
                                      newTrackName: "Generated", expectedProject: controller.project)
        let id = try #require(controller.project.tracks.first?.clips.first?.id)
        var changed = definition()
        changed.duration = ProjectTime(seconds: 1)
        try controller.updateGenerator(changed, editing: .timelineClip(id), expectedProject: controller.project)
        #expect(controller.project.media.count == 1)
        #expect(controller.project.media[0].name == "Black")
        #expect(controller.project.timelineClip(id: id)?.displayName == "Black")
    }

    @Test func updatingSharedGeneratorPreservesOtherInstancesCustomNamesAndUndo() throws {
        var project = TrimatoProject()
        let asset = definition().assetRecord()
        project.media = [asset]
        let first = try project.append(asset: asset)
        let second = try project.append(asset: asset)
        try project.renameTrackClip(id: first, to: "Opening")
        let controller = ProjectController(document: ProjectDocument(project: project))
        let before = controller.project
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.installUndoManager(undo)
        var changed = definition()
        changed.duration = ProjectTime(seconds: 1)
        undo.beginUndoGrouping()
        try controller.updateGenerator(changed, editing: .timelineClip(first), expectedProject: before)
        undo.endUndoGrouping()
        #expect(controller.project.media.count == 2)
        #expect(controller.project.timelineClip(id: first)?.displayName == "Opening")
        #expect(controller.project.timelineClip(id: second)?.assetID == asset.id)
        #expect(controller.project.asset(id: asset.id)?.generator == definition())
        undo.undo()
        #expect(controller.project == before)
    }

    @Test func filtersStayWithSplitClipsAndDoNotChangeAnotherInstance() throws {
        let asset = definition().assetRecord()
        var project = TrimatoProject()
        project.media = [asset]
        let id = try project.append(asset: asset)
        let other = try project.append(asset: asset)
        try project.setClipEffects(id: id, audio: nil, filters: [ClipFilter(kind: .blackAndWhite)])
        try project.splitClip(id: id, atTimelineTime: ProjectTime(seconds: 0.25))
        #expect(project.timelineClip(id: other)?.filters.isEmpty == true)
        #expect(project.tracks.flatMap(\.clips).filter { !$0.filters.isEmpty }.count == 2)
        let reopened = try JSONDecoder().decode(TrimatoProject.self, from: JSONEncoder().encode(project))
        #expect(reopened.tracks == project.tracks)
    }

    @Test(arguments: GeneratorKind.allCases)
    func generatedMediaIsPlayableAndRebuildsWithoutExternalFiles(kind: GeneratorKind) async throws {
        let value = definition(kind)
        let url = try GeneratorRenderer.cacheURL(for: value)
        try? FileManager.default.removeItem(at: url)
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await GeneratorRenderer.ensure(value)
        let asset = AVURLAsset(url: url)
        #expect(try await asset.load(.isPlayable))
        #expect(abs(try await asset.load(.duration).seconds - 0.5) < 0.06)
        #expect(try await asset.loadTracks(withMediaType: kind == .silence ? .audio : .video).count == 1)
    }

    @Test(arguments: ClipFilterKind.allCases)
    func everyCuratedFilterRendersWithBundledFFmpeg(kind: ClipFilterKind) async throws {
        let value = definition(kind.isAudio ? .silence : .gradient)
        let source = try await GeneratorRenderer.ensure(value)
        let output = try await ClipFilterRenderer.render(source: source, filters: [ClipFilter(kind: kind)], audio: kind.isAudio, duration: 0.5)
        defer { try? FileManager.default.removeItem(at: output) }
        let asset = AVURLAsset(url: output)
        #expect(try await asset.load(.isPlayable))
        #expect(try await asset.loadTracks(withMediaType: kind.isAudio ? .audio : .video).count == 1)
    }

    @Test func blackAndWhiteChangesPixelsAndGradientDoesNotAnimate() async throws {
        var value = definition(.gradient)
        value.color = .red
        value.secondColor = .blue
        let source = try await GeneratorRenderer.ensure(value)
        let output = try await ClipFilterRenderer.render(source: source, filters: [ClipFilter(kind: .blackAndWhite)], audio: false, duration: 0.5)
        defer { try? FileManager.default.removeItem(at: output) }
        func pixels(_ url: URL, at time: String) async throws -> Data {
            try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-hide_banner", "-ss", time, "-i", url.path, "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"]).standardOutput
        }
        let first = try await pixels(source, at: "0")
        let last = try await pixels(source, at: "0.375")
        #expect(first == last)
        let gray = try await pixels(output, at: "0")
        #expect(gray != first)
        #expect(gray.count == 64 * 48 * 3)
        for index in stride(from: 0, to: gray.count, by: 3) {
            #expect(abs(Int(gray[index]) - Int(gray[index + 1])) <= 2)
            #expect(abs(Int(gray[index]) - Int(gray[index + 2])) <= 2)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func videoFiltersPreserveAudioSamplesAndEditedTiming(hdr: Bool, edited: Bool) async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("filter-audio-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: source) }
        var arguments = ["-hide_banner", "-nostdin", "-y", "-f", "lavfi", "-i", "color=c=red:s=64x48:r=24",
                         "-f", "lavfi", "-i", "aevalsrc=0.2*sin(2*PI*(200+400*t)*t)|0.3*sin(2*PI*700*t):s=48000",
                         "-t", "1", "-c:v", "prores_ks", "-pix_fmt", "yuv422p10le", "-c:a", "pcm_s16le"]
        if hdr { arguments += ["-color_primaries", "bt2020", "-colorspace", "bt2020nc", "-color_trc", "arib-std-b67"] }
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: arguments + [source.path])
        // Noncontiguous ranges, deliberately reordered, expose audio that was
        // merely copied from the start of the source instead of following edits.
        let segments: [SourceSegment]? = edited ? [
            SourceSegment(sourceRange: ProjectTimeRange(start: ProjectTime(seconds: 0.5), duration: ProjectTime(seconds: 0.25))),
            SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 0.25)))
        ] : nil
        let output = try await ClipFilterRenderer.render(source: source, filters: [ClipFilter(kind: .blackAndWhite)],
            audio: false, duration: edited ? 0.5 : 1, segments: segments)
        defer { try? FileManager.default.removeItem(at: output) }
        let asset = AVURLAsset(url: output)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(abs(try await asset.load(.duration).seconds - (edited ? 0.5 : 1)) < 0.01)
        let actual = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-i", output.path,
            "-map", "0:a:0", "-c:a", "pcm_s16le", "-f", "s16le", "pipe:1"]).standardOutput
        var expectedArguments = ["-v", "error", "-i", source.path]
        if edited {
            expectedArguments += ["-filter_complex", "[0:a:0]atrim=start=0.5:end=0.75,asetpts=PTS-STARTPTS[a];[0:a:0]atrim=start=0:end=0.25,asetpts=PTS-STARTPTS[b];[a][b]concat=n=2:v=0:a=1[out]", "-map", "[out]"]
        } else { expectedArguments += ["-map", "0:a:0"] }
        let expected = try await FFmpegRunner.run(tool: .ffmpeg,
            arguments: expectedArguments + ["-c:a", "pcm_s16le", "-f", "s16le", "pipe:1"]).standardOutput
        #expect(!actual.isEmpty)
        #expect(actual == expected)
        let model = VideoPlayerViewModel()
        try await model.applyFilteredPreview(at: output, audio: false)
        let installed = try #require(model.player.currentItem?.asset)
        #expect(try await installed.loadTracks(withMediaType: .audio).count == 1)
        model.closeMedia()
    }

    @Test func filteringSilentVideoKeepsItPlayableWithoutInventingAudio() async throws {
        let source = try await GeneratorRenderer.ensure(definition(.gradient))
        let output = try await ClipFilterRenderer.render(source: source, filters: [ClipFilter(kind: .blackAndWhite)],
            audio: false, duration: 0.5,
            segments: [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 0.25)))])
        defer { try? FileManager.default.removeItem(at: output) }
        let asset = AVURLAsset(url: output)
        #expect(try await asset.load(.isPlayable))
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        #expect(abs(try await asset.load(.duration).seconds - 0.25) < 0.01)
    }

    @Test func editingGeneratorPreservesOtherInstancesAndUndoRestoresItsSource() throws {
        let source = definition().assetRecord()
        var project = TrimatoProject()
        project.media = [source]
        let first = try project.append(asset: source)
        let second = try project.append(asset: source)
        let controller = ProjectController(document: ProjectDocument(project: project))
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.installUndoManager(undo)
        var edited = definition(.solidColor)
        edited.color = .blue
        undo.beginUndoGrouping()
        try controller.updateGenerator(edited, editing: .timelineClip(first), expectedProject: project)
        undo.endUndoGrouping()
        #expect(controller.project.timelineClip(id: second)?.assetID == source.id)
        #expect(controller.asset(for: .timelineClip(first))?.generator == edited)
        undo.undo()
        #expect(controller.project == project)
    }

    @Test func additionalVideoFadeContinuesAcrossAnotherTrackBoundary() async throws {
        var value = definition(.solidColor)
        value.color = .white
        value.duration = ProjectTime(seconds: 2)
        let asset = value.assetRecord()
        var project = TrimatoProject()
        project.media = [asset]
        _ = try project.append(asset: asset)
        let overlay = project.createTrack(kind: .video)
        let clip = try project.append(asset: asset, toTrack: overlay)
        let extra = project.createTrack(kind: .video)
        _ = try project.insert(asset: asset, segments: [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 0.5)))], at: ProjectTime(seconds: 0.5), onTrack: extra)
        try project.addTransition(TimelineTransition(trackID: overlay, edge: .intro, kind: .video(.fade), duration: ProjectTime(seconds: 1), trailingClipID: clip))
        let result = try await ProjectCompositionBuilder.build(project: project, mediaURLs: [:])
        defer { for url in result.temporaryMediaURLs { try? FileManager.default.removeItem(at: url) } }
        let video = try #require(result.videoComposition)
        let instruction = try #require(video.instructions.first { abs($0.timeRange.start.seconds - 0.5) < 0.001 } as? AVVideoCompositionInstruction)
        var found = false
        for layer in instruction.layerInstructions {
            var start: Float = 0
            var end: Float = 0
            var range = CMTimeRange.zero
            if layer.getOpacityRamp(for: instruction.timeRange.start, startOpacity: &start, endOpacity: &end, timeRange: &range), abs(start - 0.5) < 0.001, abs(end - 1) < 0.001 { found = true }
        }
        #expect(found)
    }
}
