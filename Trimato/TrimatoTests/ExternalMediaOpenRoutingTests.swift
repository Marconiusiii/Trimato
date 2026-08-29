import Foundation
import Testing
@testable import Trimato

@Suite("External media opening")
@MainActor
struct ExternalMediaOpenRoutingTests {
    @Test func videoOpensStandaloneWhenNoProjectIsActive() {
        let url = URL(fileURLWithPath: "/tmp/Interview.mov")
        #expect(ExternalMediaOpenCoordinator.route(for: url, hasActiveProject: false) == .standaloneEditor)
    }

    @Test func videoImportsWhenAProjectIsActive() {
        let url = URL(fileURLWithPath: "/tmp/Interview.mkv")
        #expect(ExternalMediaOpenCoordinator.route(for: url, hasActiveProject: true) == .activeProject)
    }

    @Test func audioOpensStandaloneWhenNoProjectIsActive() {
        let url = URL(fileURLWithPath: "/tmp/Narration.wav")
        #expect(ExternalMediaOpenCoordinator.route(for: url, hasActiveProject: false) == .standaloneEditor)
    }

    @Test func audioImportsWhenAProjectIsActive() {
        let url = URL(fileURLWithPath: "/tmp/Music.m4a")
        #expect(ExternalMediaOpenCoordinator.route(for: url, hasActiveProject: true) == .activeProject)
    }

    @Test func projectFilesRemainDocumentGroupResponsibility() {
        let url = URL(fileURLWithPath: "/tmp/Documentary.trimato")
        #expect(ExternalMediaOpenCoordinator.route(for: url, hasActiveProject: true) == .ignore)
    }

    @Test func unrelatedFilesAreIgnored() {
        let url = URL(fileURLWithPath: "/tmp/Notes.txt")
        #expect(ExternalMediaOpenCoordinator.route(for: url, hasActiveProject: false) == .ignore)
    }

    @Test func externalEventConditionsCoverMediaWithoutClaimingProjectDocuments() {
        let conditions = ExternalMediaOpenCoordinator.mediaExternalEventConditions

        #expect(conditions.contains(".mov"))
        #expect(conditions.contains(".m4a"))
        #expect(conditions.contains(".mkv"))
        #expect(!conditions.contains(".trimato"))
    }

    @MainActor
    @Test func finderOpenUsesTheMostRecentlyActiveRegisteredProject() {
        let firstAsset = fixtureAsset(name: "First", duration: 5)
        var firstProject = TrimatoProject(name: "First Project")
        firstProject.media = [firstAsset]
        let firstController = ProjectController(document: ProjectDocument(project: firstProject))

        let secondAsset = fixtureAsset(name: "Second", duration: 5)
        var secondProject = TrimatoProject(name: "Second Project")
        secondProject.media = [secondAsset]
        let secondController = ProjectController(document: ProjectDocument(project: secondProject))
        var firstOpened: EditorSelection?
        var secondOpened: EditorSelection?
        var standaloneURL: URL?
        let coordinator = ExternalMediaOpenCoordinator()
        coordinator.register(controller: firstController) { firstOpened = $0 }
        coordinator.register(controller: secondController) { secondOpened = $0 }
        defer {
            coordinator.unregister(controller: firstController)
            coordinator.unregister(controller: secondController)
        }
        coordinator.activate(controller: secondController)

        coordinator.handle(URL(fileURLWithPath: secondAsset.originalPath)) {
            standaloneURL = $0
        }

        #expect(firstOpened == nil)
        #expect(secondOpened == .asset(secondAsset.id))
        #expect(standaloneURL == nil)
    }

    @MainActor
    @Test func activeProjectControllerTracksWindowActivationAndClosure() {
        let firstController = ProjectController(
            document: ProjectDocument(project: TrimatoProject(name: "First"))
        )
        let secondController = ProjectController(
            document: ProjectDocument(project: TrimatoProject(name: "Second"))
        )
        let coordinator = ExternalMediaOpenCoordinator()

        coordinator.register(controller: firstController) { _ in }
        coordinator.register(controller: secondController) { _ in }
        #expect(coordinator.activeProjectController === firstController)

        coordinator.activate(controller: secondController)
        #expect(coordinator.activeProjectController === secondController)

        coordinator.unregister(controller: secondController)
        #expect(coordinator.activeProjectController === firstController)

        coordinator.unregister(controller: firstController)
        #expect(coordinator.activeProjectController == nil)
    }
}
