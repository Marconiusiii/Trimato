import Foundation
import Testing
@testable import Trimato

@Suite("External media opening")
struct ExternalMediaOpenRoutingTests {
    @Test func videoOpensStandaloneWhenNoProjectIsActive() {
        let url = URL(fileURLWithPath: "/tmp/Interview.mov")
        #expect(ExternalMediaOpenCoordinator.route(for: url, hasActiveProject: false) == .standaloneEditor)
    }

    @Test func videoImportsWhenAProjectIsActive() {
        let url = URL(fileURLWithPath: "/tmp/Interview.mkv")
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
}
