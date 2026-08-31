import Foundation
import Testing
@testable import Trimato

@Suite(.serialized)
@MainActor
struct TimelineTrackOrderTests {
    private func projectWithPrimaryTracks() -> TrimatoProject {
        var project = TrimatoProject()
        project.tracks = [
            TimelineTrack(name: "Primary Video", kind: .video, role: .primaryVideo),
            TimelineTrack(name: "Primary Audio", kind: .audio, role: .primaryAudio)
        ]
        return project
    }

    @Test func newVideoTracksAppearAbovePictureAndAudioTracksBelowPrimaryAudio() {
        var project = projectWithPrimaryTracks()
        let primary = project.tracks.map(\.id)
        let title = project.createTrack(kind: .video, name: "Title")
        let music = project.createTrack(kind: .audio, name: "Music")
        let subtitle = project.createTrack(kind: .video, name: "Subtitle")
        let effects = project.createTrack(kind: .audio, name: "Effects")

        #expect(project.orderedTimelineTracks.map(\.id) == [subtitle, title, primary[0], primary[1], music, effects])
        // Reading the editing order must not change the stored order used by compositing.
        #expect(project.tracks.map(\.id) == primary + [title, music, subtitle, effects])
    }

    @Test func existingInterleavedProjectsDisplayCorrectlyWithoutChangingSavedLayers() throws {
        var project = projectWithPrimaryTracks()
        _ = project.createTrack(kind: .audio, name: "Music")
        _ = project.createTrack(kind: .video, name: "Existing title")
        _ = project.createTrack(kind: .audio, name: "Effects")
        _ = project.createTrack(kind: .video, name: "Existing subtitle")
        let stored = project.tracks
        let reopened = try JSONDecoder().decode(TrimatoProject.self, from: JSONEncoder().encode(project))
        #expect(reopened.tracks == stored)
        #expect(reopened.orderedTimelineTracks.map(\.name) == [
            "Existing subtitle", "Existing title", "Primary Video", "Primary Audio", "Music", "Effects"
        ])
    }

    @Test func videoMoveUpChangesTheFrontToBackOrderAndPreservesOtherTracks() throws {
        var project = projectWithPrimaryTracks()
        let primary = project.tracks
        let first = project.createTrack(kind: .video, name: "First layer")
        let music = project.createTrack(kind: .audio, name: "Music")
        let second = project.createTrack(kind: .video, name: "Second layer")
        let third = project.createTrack(kind: .video, name: "Third layer")
        let audio = project.track(id: music)

        #expect(project.canMoveTrack(id: first, by: -1))
        try project.moveTrack(id: first, by: -1)
        #expect(project.orderedTimelineTracks.prefix(3).map(\.id) == [third, first, second])
        #expect(project.tracks.filter { $0.kind == .video && $0.role == .additional }.map(\.id) == [second, first, third])
        try project.moveTrack(id: first, by: -1)
        #expect(project.orderedTimelineTracks.first?.id == first)
        #expect(project.tracks.last { $0.kind == .video && $0.role == .additional }?.id == first)
        #expect(!project.canMoveTrack(id: first, by: -1))
        try project.moveTrack(id: first, by: 1)
        #expect(project.orderedTimelineTracks.prefix(3).map(\.id) == [third, first, second])
        #expect(Array(project.tracks.prefix(2)) == primary)
        #expect(project.track(id: music) == audio)
    }

    @Test func audioMovementStaysBelowPrimaryAudioAndDoesNotReorderPicture() throws {
        var project = projectWithPrimaryTracks()
        let primary = project.tracks.map(\.id)
        let music = project.createTrack(kind: .audio, name: "Music")
        let title = project.createTrack(kind: .video, name: "Title")
        let effects = project.createTrack(kind: .audio, name: "Effects")
        #expect(!project.canMoveTrack(id: music, by: -1))
        #expect(!project.canMoveTrack(id: primary[0], by: 1))
        #expect(!project.canMoveTrack(id: primary[1], by: -1))
        try project.moveTrack(id: primary[0], by: 1)
        try project.moveTrack(id: music, by: -1)
        try project.moveTrack(id: effects, by: -1)
        #expect(project.orderedTimelineTracks.map(\.id) == [title, primary[0], primary[1], effects, music])
        #expect(!project.canMoveTrack(id: music, by: 1))
        #expect(throws: ProjectTimelineError.trackNotFound) { try project.moveTrack(id: UUID(), by: 1) }
    }

    @Test func generatedTitleAndSilenceUseTheSharedDestinationOrder() throws {
        let controller = ProjectController(document: ProjectDocument(project: projectWithPrimaryTracks()))
        var title = GeneratorDefinition()
        title.kind = .text
        title.textSettings.text = "Title"
        title.textSettings.background = .transparent
        try controller.placeGenerator(title, placement: .insert, at: .zero, trackID: nil,
                                      newTrackName: "Title", expectedProject: controller.project)
        let titleID = try #require(controller.activeTimelineTrackID)
        #expect(controller.project.orderedTimelineTracks.first?.id == titleID)
        #expect(controller.project.orderedTimelineTracks.map(\.name) == ["Title", "Primary Video", "Primary Audio"])

        var silence = GeneratorDefinition()
        silence.kind = .silence
        try controller.placeGenerator(silence, placement: .insert, at: .zero, trackID: nil,
                                      newTrackName: "Silence", expectedProject: controller.project)
        #expect(controller.project.orderedTimelineTracks.map(\.name) == ["Title", "Primary Video", "Primary Audio", "Silence"])
        let session = GeneratorSession(controller: controller)
        #expect(session.compatibleTracks.map(\.name) == ["Title", "Primary Video"])
        #expect(session.trackID == controller.project.tracks.first { $0.role == .primaryVideo }?.id)
        let previous = session.definition
        session.definition.kind = .silence
        session.definitionChanged(from: previous)
        #expect(session.compatibleTracks.map(\.name) == ["Primary Audio", "Silence"])
        #expect(session.trackID == controller.project.tracks.first { $0.role == .primaryAudio }?.id)
    }

    @Test func movingTrackKeepsSelectionAndSupportsUndo() throws {
        var project = projectWithPrimaryTracks()
        let first = project.createTrack(kind: .video, name: "First")
        let second = project.createTrack(kind: .video, name: "Second")
        let controller = ProjectController(document: ProjectDocument(project: project))
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.installUndoManager(undo)
        controller.activeTimelineTrackID = first
        undo.beginUndoGrouping()
        controller.moveActiveTrack(by: -1)
        undo.endUndoGrouping()
        #expect(controller.project.orderedTimelineTracks.first?.id == first)
        #expect(controller.activeTimelineTrackID == first)
        undo.undo()
        #expect(controller.project.orderedTimelineTracks.first?.id == second)
        undo.redo()
        #expect(controller.project.orderedTimelineTracks.first?.id == first)
    }
}
