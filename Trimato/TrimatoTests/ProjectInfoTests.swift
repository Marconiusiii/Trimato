import Foundation
import Testing
@testable import Trimato

@Suite(.serialized)
@MainActor
struct ProjectInfoTests {
    @Test func snapshotsDoNotChangeWhenTheProjectChanges() {
        var project = TrimatoProject()
        project.name = "Interview"
        project.targetDuration = ProjectTime(seconds: 90)
        let snapshot = ProjectInfoSnapshot.make(
            target: .selection(.project),
            project: project,
            playhead: .zero,
            activeTrackID: nil
        )

        project.name = "Revised Interview"
        project.targetDuration = nil

        #expect(snapshot.title == "Interview Info")
        #expect(snapshot.rows.contains(ProjectInfoRow("Name", "Interview")))
        #expect(snapshot.rows.contains(ProjectInfoRow("Target Length", "00:01:30.000")))
        #expect(!snapshot.rows.contains { $0.value == "Revised Interview" })
    }

    @Test func focusedFolderAndEditorProduceTheirOwnInformation() {
        var project = TrimatoProject()
        project.name = "Documentary"
        let folder = ProjectFolder(name: "Interviews", assetIDs: [UUID(), UUID()])
        project.folders = [folder]

        let folderSnapshot = ProjectInfoSnapshot.make(
            target: .folder(folder.id), project: project, playhead: .zero, activeTrackID: nil
        )
        let editorSnapshot = ProjectInfoSnapshot.make(
            target: .editor, project: project,
            playhead: ProjectTime(seconds: 12), activeTrackID: nil
        )

        #expect(folderSnapshot.title == "Interviews Info")
        #expect(folderSnapshot.rows.contains(ProjectInfoRow("Clips", "2")))
        #expect(editorSnapshot.title == "Documentary Info")
        #expect(editorSnapshot.rows.contains(ProjectInfoRow("Project", "Documentary")))
    }
}
