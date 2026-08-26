import Combine
import Foundation
import Testing
@testable import Trimato

struct ProjectSaveStateTests {
    @Test @MainActor func emptyUntitledDocumentStartsInInitialProjectCreation() {
        let controller = ProjectController(document: ProjectDocument())

        #expect(controller.isCreatingProject)
        #expect(controller.isShowingProjectSettings)

        controller.completeProjectSettings()

        #expect(!controller.isCreatingProject)
        #expect(!controller.isShowingProjectSettings)
    }

    @Test @MainActor func cancellingInitialProjectCreationRequestsProjectClosure() {
        let controller = ProjectController(document: ProjectDocument())
        var requestedClosure = false
        controller.installCloseProjectAction { requestedClosure = true }

        controller.cancelProjectSettings()

        #expect(requestedClosure)
        #expect(controller.isCreatingProject)
    }

    @Test @MainActor func cancellingSettingsForAnExistingProjectOnlyDismissesSettings() {
        let document = ProjectDocument(project: TrimatoProject(name: "Existing Project"))
        let controller = ProjectController(document: document)
        var requestedClosure = false
        controller.installCloseProjectAction { requestedClosure = true }
        controller.showProjectSettings()

        controller.cancelProjectSettings()

        #expect(!requestedClosure)
        #expect(!controller.isCreatingProject)
        #expect(!controller.isShowingProjectSettings)
    }

    @Test func launcherReturnsOnlyAfterTheLastProjectClosesOutsideTermination() {
        #expect(ProjectWindowSaveCoordinator.shouldRestoreLauncher(
            isApplicationTerminating: false,
            otherProjectDocumentCount: 0
        ))
        #expect(!ProjectWindowSaveCoordinator.shouldRestoreLauncher(
            isApplicationTerminating: false,
            otherProjectDocumentCount: 1
        ))
        #expect(!ProjectWindowSaveCoordinator.shouldRestoreLauncher(
            isApplicationTerminating: true,
            otherProjectDocumentCount: 0
        ))
    }

    @Test func newDocumentStartsCleanAndBecomesDirtyAfterAProjectChange() {
        let document = ProjectDocument(project: TrimatoProject(name: "Initial"))

        #expect(!document.hasUnsavedChanges)

        var changed = document.project
        changed.name = "Changed"
        document.project = changed

        #expect(document.hasUnsavedChanges)
    }

    @Test func explicitSaveEstablishesANewCleanBaseline() {
        let document = ProjectDocument(project: TrimatoProject(name: "Initial"))
        var changed = document.project
        changed.name = "Saved"
        document.project = changed

        document.markCurrentProjectAsExplicitlySaved()

        #expect(!document.hasUnsavedChanges)
        #expect(document.project.name == "Saved")
    }

    @Test func establishingTheSavedBaselineDoesNotPublishAnotherDocumentChange() {
        let document = ProjectDocument(project: TrimatoProject(name: "Initial"))
        var publishedChanges = 0
        let subscription = document.objectWillChange.sink { publishedChanges += 1 }
        var changed = document.project
        changed.name = "Saved"
        document.project = changed
        let changesBeforeBaseline = publishedChanges

        document.markCurrentProjectAsExplicitlySaved()

        #expect(changesBeforeBaseline > 0)
        #expect(publishedChanges == changesBeforeBaseline)
        #expect(!document.hasUnsavedChanges)
        _ = subscription
    }

    @Test func projectCreatedFromAStandaloneClipStartsUnsaved() {
        let document = ProjectDocument(
            project: TrimatoProject(name: "Interview Project"),
            isExplicitlySaved: false
        )

        #expect(document.hasUnsavedChanges)
        #expect(document.unsavedChangesDidChange.value)
    }

    @Test func updatingATimelineClipMarksTheProjectDirty() throws {
        let source = fixtureAsset(name: "Interview", duration: 10)
        var savedProject = TrimatoProject(name: "Interview Project")
        savedProject.media = [source]
        let clipID = try savedProject.append(asset: source)
        let document = ProjectDocument(project: savedProject)
        var changedProject = document.project

        try changedProject.updateTimelineClip(id: clipID, segments: [
            SourceSegment(sourceRange: ProjectTimeRange(
                start: ProjectTime(seconds: 1),
                duration: ProjectTime(seconds: 3)
            ))
        ])
        document.project = changedProject

        #expect(document.hasUnsavedChanges)
    }

    @Test func discardRestoresTheLastExplicitlySavedProject() {
        let document = ProjectDocument(project: TrimatoProject(name: "Saved"))
        var changed = document.project
        changed.name = "Unsaved"
        document.project = changed

        let discarded = document.restoreExplicitlySavedProject()

        #expect(document.project.name == "Saved")
        #expect(discarded.name == "Unsaved")
        #expect(!document.hasUnsavedChanges)
    }

    @Test func failedDiscardCanReinstateTheUnsavedProject() {
        let document = ProjectDocument(project: TrimatoProject(name: "Saved"))
        var changed = document.project
        changed.name = "Unsaved"
        document.project = changed

        let discarded = document.restoreExplicitlySavedProject()
        document.reinstateDiscardedProject(discarded)

        #expect(document.project.name == "Unsaved")
        #expect(document.hasUnsavedChanges)
    }

    @Test func playbackHousekeepingDoesNotDirtyASavedProject() {
        let asset = fixtureAsset(name: "Interview", duration: 10)
        var project = TrimatoProject(name: "Saved")
        project.media = [asset]
        let document = ProjectDocument(project: project)
        let fingerprint = SourceMediaFingerprint(
            fileSize: 1_024,
            modificationTime: 123,
            proxyFormatVersion: SourceMediaFingerprint.proxyFormatVersion
        )

        document.updatePlaybackPreparation(
            assetID: asset.id,
            playbackMode: .cachedProxy,
            proxyCacheKey: UUID(),
            sourceFingerprint: fingerprint
        )

        #expect(!document.hasUnsavedChanges)
        #expect(document.project.media[0].sourceFingerprint == fingerprint)
    }

    @Test func playbackHousekeepingDoesNotPublishANativeDocumentChange() {
        let asset = fixtureAsset(name: "Interview", duration: 10)
        var project = TrimatoProject(name: "Saved")
        project.media = [asset]
        let document = ProjectDocument(project: project)
        var publishedChanges = 0
        let subscription = document.objectWillChange.sink { publishedChanges += 1 }

        document.updatePlaybackPreparation(
            assetID: asset.id,
            playbackMode: .nativePassthrough,
            proxyCacheKey: nil,
            sourceFingerprint: SourceMediaFingerprint(
                fileSize: 4_096,
                modificationTime: 789,
                proxyFormatVersion: SourceMediaFingerprint.proxyFormatVersion
            )
        )

        #expect(publishedChanges == 0)
        #expect(!document.hasUnsavedChanges)
        _ = subscription
    }

    @Test func playbackHousekeepingPreservesRealUnsavedChanges() {
        let asset = fixtureAsset(name: "Interview", duration: 10)
        var project = TrimatoProject(name: "Saved")
        project.media = [asset]
        let document = ProjectDocument(project: project)
        var changed = document.project
        changed.name = "Unsaved Name"
        document.project = changed

        document.updatePlaybackPreparation(
            assetID: asset.id,
            playbackMode: .nativePassthrough,
            proxyCacheKey: nil,
            sourceFingerprint: SourceMediaFingerprint(
                fileSize: 2_048,
                modificationTime: 456,
                proxyFormatVersion: SourceMediaFingerprint.proxyFormatVersion
            )
        )

        #expect(document.hasUnsavedChanges)
        let discarded = document.restoreExplicitlySavedProject()
        #expect(discarded.name == "Unsaved Name")
        #expect(document.project.name == "Saved")
        #expect(document.project.media[0].playbackMode == .nativePassthrough)
    }
}
