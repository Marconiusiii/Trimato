import Foundation
import Testing
@testable import Trimato

@Suite("Project preview invalidation")
@MainActor
struct ProjectPreviewInvalidationTests {
    private func fixture() throws -> TrimatoProject {
        let asset = MediaAssetRecord(name: "Imported", originalPath: "/tmp/imported.mov",
                                    duration: ProjectTime(seconds: 10), naturalWidth: 640, naturalHeight: 480,
                                    frameRate: 30, hasAudio: true,
                                    sourceEdit: [SourceSegment(sourceRange: ProjectTimeRange(
                                        start: .zero, duration: ProjectTime(seconds: 10)))])
        var project = TrimatoProject()
        project.media = [asset]
        _ = try project.append(asset: asset)
        return project
    }

    @Test func importedMarkersSaveAndUndoWithoutInvalidatingProjectPlayback() throws {
        let controller = ProjectController(document: ProjectDocument(project: try fixture()))
        let asset = controller.project.media[0]
        let context = ClipPlacementCommandContext(controller: controller, editSelection: .asset(asset.id),
                                                  segments: asset.sourceEdit)
        let original = controller.project
        let input = ProjectPreviewInput(original)
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.installUndoManager(undo)
        let selection = [SourceSegment(sourceRange: ProjectTimeRange(
            start: ProjectTime(seconds: 2), duration: ProjectTime(seconds: 4)))]
        undo.beginUndoGrouping()
        context.setSegments(selection)
        undo.endUndoGrouping()
        #expect(controller.project.media[0].sourceEdit == selection)
        #expect(controller.project.tracks == original.tracks)
        #expect(ProjectPreviewInput(controller.project) == input)
        undo.undo()
        #expect(controller.project == original)
        #expect(ProjectPreviewInput(controller.project) == input)
        undo.redo()
        #expect(controller.project.media[0].sourceEdit == selection)
        #expect(ProjectPreviewInput(controller.project) == input)
    }

    @Test func browserMetadataAndUnusedImportsDoNotRebuildPlayback() throws {
        let original = try fixture()
        var changed = original
        changed.name = "Renamed project"
        changed.folders = [ProjectFolder(name: "Interviews", assetIDs: [changed.media[0].id])]
        changed.targetDuration = ProjectTime(seconds: 30)
        var unused = changed.media[0]
        unused.id = UUID()
        unused.sourceEdit = []
        changed.media.append(unused)
        changed.media[0].name = "Renamed source"
        #expect(ProjectPreviewInput(changed) == ProjectPreviewInput(original))
    }

    @Test func timelineSegmentsFiltersAndAudioStillRebuildPlayback() throws {
        let original = try fixture()
        let input = ProjectPreviewInput(original)
        var changed = original
        changed.tracks[0].clips[0].segments[0].sourceRange.duration = ProjectTime(seconds: 3)
        #expect(ProjectPreviewInput(changed) != input)
        changed = original
        changed.tracks[0].clips[0].filters = [ClipFilter(kind: .blackAndWhite)]
        #expect(ProjectPreviewInput(changed) != input)
        changed = original
        changed.tracks[0].clips[0].audioSettings.gainDecibels = -6
        #expect(ProjectPreviewInput(changed) != input)
        changed = original
        changed.tracks[0].isMuted.toggle()
        #expect(ProjectPreviewInput(changed) != input)
        changed = original
        changed.tracks[0].clips.removeAll()
        #expect(ProjectPreviewInput(changed) != input)
    }

    @Test func transitionsFormatRelinkingAndGeneratorEditsStillRebuildPlayback() throws {
        let original = try fixture()
        let input = ProjectPreviewInput(original)
        var changed = original
        let clip = changed.tracks[0].clips[0]
        changed.transitions.append(TimelineTransition(trackID: changed.tracks[0].id, edge: .intro,
                                                       kind: .video(.fade), duration: ProjectTime(seconds: 1),
                                                       leadingClipID: nil, trailingClipID: clip.id))
        #expect(ProjectPreviewInput(changed) != input)
        changed = original
        changed.format.frameRate = 24
        #expect(ProjectPreviewInput(changed) != input)
        changed = original
        changed.media[0].originalPath = "/tmp/relinked.mov"
        #expect(ProjectPreviewInput(changed) != input)
        changed = original
        changed.media[0].generator = GeneratorDefinition()
        #expect(ProjectPreviewInput(changed) != input)
        let generated = changed
        changed.media[0].generator?.color = .red
        #expect(ProjectPreviewInput(changed) != ProjectPreviewInput(generated))
    }
}
