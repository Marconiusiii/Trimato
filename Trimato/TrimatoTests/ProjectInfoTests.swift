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
        #expect(snapshot.rows.contains(ProjectInfoRow("Target Length", "1 minute, 30 seconds, 0 milliseconds")))
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

    @Test func mediaDetailsIncludeCodecsEncoderAndSpokenMilliseconds() {
        let asset = MediaAssetRecord(
            name: "Interview",
            originalPath: "/tmp/interview.mov",
            duration: ProjectTime(seconds: 9.238),
            naturalWidth: 1920,
            naturalHeight: 1080,
            frameRate: 30,
            hasAudio: true,
            sourceEdit: [SourceSegment(sourceRange: ProjectTimeRange(
                start: .zero,
                duration: ProjectTime(seconds: 9.238)
            ))]
        )
        var project = TrimatoProject()
        project.media = [asset]
        let details = FFmpegMediaProbe.Report.TechnicalDetails(
            container: "QuickTime / MOV",
            videoCodec: "H.264",
            audioCodec: "AAC",
            encoder: "Apple AVFoundation"
        )

        let snapshot = ProjectInfoSnapshot.make(
            target: .selection(.asset(asset.id)),
            project: project,
            playhead: .zero,
            activeTrackID: nil,
            technicalDetails: details
        )

        #expect(snapshot.rows.contains(ProjectInfoRow("Length", "9 seconds, 238 milliseconds")))
        #expect(snapshot.rows.contains(ProjectInfoRow("Container", "QuickTime / MOV")))
        #expect(snapshot.rows.contains(ProjectInfoRow("Video Codec", "H.264")))
        #expect(snapshot.rows.contains(ProjectInfoRow("Audio Codec", "AAC")))
        #expect(snapshot.rows.contains(ProjectInfoRow("Encoder", "Apple AVFoundation")))
    }
}
