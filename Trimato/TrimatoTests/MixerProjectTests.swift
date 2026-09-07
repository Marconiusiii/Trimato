import Foundation
import Testing
@testable import Trimato

@MainActor
struct MixerProjectTests {
    private func project() -> TrimatoProject {
        var project = TrimatoProject(name: "Mixer test")
        project.tracks = [TimelineTrack(name: "Voice", kind: .audio), TimelineTrack(name: "Music", kind: .audio)]
        return project
    }

    @Test func savedMixAndLegacyDefaults() throws {
        var value = project()
        value.masterVolumeDB = -3
        value.tracks[0].mix.volumeDB = -6
        value.tracks[0].mix.pan = -0.5
        value.tracks[0].mix.balance = 0.25
        value.tracks[0].mix.width = 1.5
        value.tracks[0].mix.routing = .swap
        value.tracks[0].isMuted = true
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(TrimatoProject.self, from: data) == value)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "masterVolumeDB")
        var tracks = try #require(legacy["tracks"] as? [[String: Any]])
        for i in tracks.indices { tracks[i].removeValue(forKey: "mix") }
        legacy["tracks"] = tracks
        let decoded = try JSONDecoder().decode(TrimatoProject.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.masterVolumeDB == 0)
        #expect(decoded.tracks.allSatisfy { $0.mix == .neutral })
        #expect(decoded.tracks[0].isMuted)
    }

    @Test func gestureSavesAndUndoesWithoutRebuildingPlayback() {
        let document = ProjectDocument(project: project())
        let controller = ProjectController(document: document)
        let before = controller.project
        let undo = UndoManager(); undo.groupsByEvent = false
        controller.installUndoManager(undo)
        undo.beginUndoGrouping()
        controller.mixerAdjustmentEditing(true)
        for volume in [-1.0, -3.0, -6.0] {
            var settings = TrackMixSettings(); settings.volumeDB = volume
            controller.setTrackMix(before.tracks[0].id, settings: settings)
        }
        controller.mixerAdjustmentEditing(false)
        undo.endUndoGrouping()
        #expect(document.hasUnsavedChanges)
        #expect(controller.project.tracks[0].mix.volumeDB == -6)
        #expect(ProjectPreviewInput(before) == ProjectPreviewInput(controller.project))
        undo.undo()
        #expect(controller.project == before)
        #expect(!document.hasUnsavedChanges)
        undo.redo()
        #expect(controller.project.tracks[0].mix.volumeDB == -6)
    }

    @Test func soloDoesNotChangeSavedProjectAndSelectionDoesNotChangePlayhead() {
        let controller = ProjectController(document: ProjectDocument(project: project()))
        let player = ProjectPlayerViewModel()
        let session = MixerSession(controller: controller, player: player)
        let before = controller.project, playhead = player.currentTime
        session.selectedID = before.tracks[1].id
        session.solo(true)
        #expect(session.soloIDs == [before.tracks[1].id])
        #expect(controller.project == before)
        #expect(player.currentTime == playhead)
        #expect(!controller.document.hasUnsavedChanges)
        session.close()
    }
}
