import Foundation
import Testing
@testable import Trimato

@Suite("Markers and export options")
@MainActor
struct MarkerExportTests {
    func fixture() throws -> TrimatoProject {
        let asset = MediaAssetRecord(name: "Movie", originalPath: "/tmp/movie.mov",
            duration: ProjectTime(seconds: 60), naturalWidth: 640, naturalHeight: 360,
            frameRate: 30, hasAudio: true,
            sourceEdit: [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 60)))])
        var project = TrimatoProject()
        project.media = [asset]
        _ = try project.append(asset: asset)
        return project
    }

    @Test func markerTimesSurviveClipEditsAndRoundTripWithoutRebuildingPreview() throws {
        var project = try fixture()
        let duration = project.duration
        let preview = ProjectPreviewInput(project)
        let later = project.insertMarker(at: ProjectTime(seconds: 45.125))
        let earlier = project.insertMarker(at: ProjectTime(seconds: 2.5))
        #expect(later.title == "Marker 1" && earlier.title == "Marker 2")
        #expect(project.markerTrack?.sortedMarkers.map(\.id) == [earlier.id, later.id])
        #expect(project.duration == duration)
        #expect(ProjectPreviewInput(project) == preview)
        let decoded = try JSONDecoder().decode(TrimatoProject.self, from: JSONEncoder().encode(project))
        #expect(decoded.markerTrack == project.markerTrack)
        let markerTrack = try #require(project.markerTrack)
        #expect(!markerTrack.isMagnetic)
        #expect(throws: (any Error).self) { try project.setTrackMagnetic(id: markerTrack.id, enabled: true) }
        let video = try #require(project.tracks.firstIndex { $0.kind == .video })
        project.tracks[video].clips[0].segments[0].sourceRange.duration = ProjectTime(seconds: 10)
        #expect(project.markerTrack?.markers == [later, earlier])
        let markers = try #require(project.tracks.firstIndex { $0.kind == .markers })
        project.tracks[markers].markers.removeAll { $0.id == earlier.id }
        #expect(project.insertMarker(at: .zero).title == "Marker 3")
    }

    @Test func markerCreationUndoRedoUsesOneOperation() throws {
        let controller = ProjectController(document: ProjectDocument(project: try fixture()))
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.installUndoManager(undo)
        undo.beginUndoGrouping()
        controller.createMarker(at: ProjectTime(seconds: 4.125))
        undo.endUndoGrouping()
        let marker = try #require(controller.project.markerTrack?.markers.first)
        #expect(controller.activeTimelineTrackID == controller.project.markerTrack?.id)
        #expect(controller.editingMarker == nil)
        undo.undo()
        #expect(controller.project.markerTrack == nil)
        undo.redo()
        #expect(controller.project.markerTrack?.markers.first == marker)
    }

    @Test func captionVisibilityDoesNotDestroyExportCues() throws {
        var project = try fixture()
        try project.addCaptionCues([CaptionCue(start: .zero, end: ProjectTime(seconds: 1), text: "Test")])
        let controller = ProjectController(document: ProjectDocument(project: project))
        controller.setCaptionsVisible(false)
        #expect(controller.project.visibleCaptionCues.isEmpty)
        #expect(controller.project.captionTrack?.captionCues.count == 1)
        #expect(ProjectPreviewInput(controller.project) == ProjectPreviewInput(project))
        controller.setCaptionsVisible(true)
        #expect(controller.project.visibleCaptionCues.count == 1)
    }

    @Test func audioOnlyChoiceRemainsAvailableForSpatialVideo() {
        let model = ExportFormatSelectionModel(selectedFormat: .h264QuickTime, hasCaptions: true)
        model.allFormats = ExportFormat.projectFormats
        model.offersAudioChoice = true
        model.audioMode = .preserveSpatial
        #expect(!model.includeCaptions)
        model.audioOnly = true
        #expect(model.selectedFormat.isAudioOnly)
        #expect(model.availableFormats.contains(.wav24))
        #expect(model.audioMode == .highQualityStereo)
        #expect(model.captionDelivery == .webVTT)
    }

    @Test func embedEscapesTextAndIncludesNativeCaptionControls() {
        let html = WebVideoMarkup.fragment(title: "A < B & C", captions: true, language: "en", languageName: "English")
        #expect(html.contains("<video controls playsinline"))
        #expect(html.contains("kind=\"captions\""))
        #expect(html.contains("srclang=\"en\""))
        #expect(html.contains("default>"))
        #expect(html.contains("A &lt; B &amp; C"))
        #expect(!html.contains("autoplay"))
        #expect(!html.contains("aria-"))
        #expect(!WebVideoMarkup.fragment(title: "Movie", captions: false, language: "en", languageName: "English").contains("<track"))
    }
}
