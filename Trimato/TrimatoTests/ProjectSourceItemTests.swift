import Foundation
import Testing
@testable import Trimato

@Suite("Project source hierarchy")
struct ProjectSourceItemTests {
    @Test func timelineAndClipsFolderAppearUnderTheProjectRoot() {
        let first = makeAsset(name: "Interview")
        let second = makeAsset(name: "Cutaway")
        var project = TrimatoProject(name: "Documentary")
        project.media = [first, second]

        let root = ProjectSourceItem.hierarchy(for: project)

        #expect(root.id == .project(project.id))
        #expect(root.children.map(\.id) == [
            .timeline(project.id),
            .clips(project.id),
        ])
        #expect(root.children[1].children.map(\.id) == [.asset(first.id), .asset(second.id)])
    }

    @Test func folderedClipsAppearOnceInsideTheirFolder() {
        let unfiled = makeAsset(name: "Interview")
        let filed = makeAsset(name: "B-roll")
        let folder = ProjectFolder(name: "Exterior", assetIDs: [filed.id])
        var project = TrimatoProject(name: "Documentary")
        project.media = [unfiled, filed]
        project.folders = [folder]

        let root = ProjectSourceItem.hierarchy(for: project)

        #expect(root.children.map(\.id) == [
            .timeline(project.id),
            .clips(project.id),
            .folder(folder.id),
        ])
        #expect(root.children[1].children.map(\.id) == [.asset(unfiled.id)])
        #expect(root.children.last?.children.map(\.id) == [.asset(filed.id)])
    }

    @Test func pastedSourceFocusChoosesTheFirstNewAssetInImportOrder() throws {
        let existing = makeAsset(name: "Existing")
        let firstPasted = makeAsset(name: "First Pasted")
        let secondPasted = makeAsset(name: "Second Pasted")

        let focusedID = ProjectSourcePasteFocus.firstImportedAssetID(
            existingAssetIDs: [existing.id],
            assets: [existing, firstPasted, secondPasted]
        )

        #expect(focusedID == firstPasted.id)
    }

    @Test func pastedSourceFocusHasNoTargetWhenImportAddsNothing() {
        let existing = makeAsset(name: "Existing")

        let focusedID = ProjectSourcePasteFocus.firstImportedAssetID(
            existingAssetIDs: [existing.id],
            assets: [existing]
        )

        #expect(focusedID == nil)
    }

    @Test func pastedSourceFocusWaitsUntilImportAndProgressUpdatesFinish() {
        let assetID = UUID()
        #expect(ProjectSourcePasteFocus.shouldRestoreFocus(
            pendingAssetID: assetID,
            importIsRunning: true
        ) == false)
        #expect(ProjectSourcePasteFocus.shouldRestoreFocus(
            pendingAssetID: assetID,
            importIsRunning: false
        ))
        #expect(ProjectSourcePasteFocus.shouldRestoreFocus(
            pendingAssetID: nil,
            importIsRunning: false
        ) == false)
    }

    @Test func sourceDeletionConfirmationIsNamedAndExplainsTimelineRemoval() {
        #expect(ProjectSourceDeletionConfirmation.title == "Delete Source Clip?")
        #expect(ProjectSourceDeletionConfirmation.message(
            clipName: "Interview",
            timelineUseCount: 0
        ) == "Remove Interview from Project Source? This can be undone.")
        #expect(ProjectSourceDeletionConfirmation.message(
            clipName: "Interview",
            timelineUseCount: 2
        ) == "Interview is used by 2 timeline clips. Deleting it from Project Source will also remove those timeline clips and their transitions. This can be undone.")
    }

    @Test func sourceDeletionFocusChoosesNextThenPreviousThenClips() {
        let first = makeAsset(name: "First")
        let second = makeAsset(name: "Second")
        let third = makeAsset(name: "Third")
        let projectID = UUID()

        #expect(ProjectSourceDeletionFocus.target(
            afterDeleting: second.id,
            from: [first, second, third],
            projectID: projectID
        ) == .asset(third.id))
        #expect(ProjectSourceDeletionFocus.target(
            afterDeleting: third.id,
            from: [first, second, third],
            projectID: projectID
        ) == .asset(second.id))
        #expect(ProjectSourceDeletionFocus.target(
            afterDeleting: first.id,
            from: [first],
            projectID: projectID
        ) == .clips(projectID))
    }

    private func makeAsset(name: String) -> MediaAssetRecord {
        MediaAssetRecord(
            name: name,
            originalPath: "/tmp/\(name).mov",
            duration: ProjectTime(seconds: 5),
            hasAudio: true,
            sourceEdit: [SourceSegment(sourceRange: ProjectTimeRange(
                start: .zero,
                duration: ProjectTime(seconds: 5)
            ))]
        )
    }
}
