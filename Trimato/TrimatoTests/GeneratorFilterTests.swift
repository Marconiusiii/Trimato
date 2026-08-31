import AVFoundation
import Foundation
import Testing
@testable import Trimato

@Suite(.serialized)
@MainActor
struct GeneratorFilterTests {
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
