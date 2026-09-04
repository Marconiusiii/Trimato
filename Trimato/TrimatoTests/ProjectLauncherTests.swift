import Foundation
import AppKit
import Testing
@testable import Trimato

@Suite("Project launcher")
struct ProjectLauncherTests {
    @Test @MainActor func projectSettingsProduceAConfiguredProjectForSaving() {
        let values = ProjectSettingsValues(
            name: "  Phone Interview  ",
            format: ProjectFormat(mode: .custom, width: 1_080, height: 1_920, frameRate: 30),
            targetDuration: ProjectTime(seconds: 90)
        )

        let project = values.applying(to: TrimatoProject())

        #expect(project.name == "Phone Interview")
        #expect(project.format == values.format)
        #expect(project.targetDuration == ProjectTime(seconds: 90))
        #expect(project.media.isEmpty)
        #expect(project.primaryTimeline.isEmpty)
    }

    @Test func blankProjectNameUsesTheDefaultName() {
        let values = ProjectSettingsValues(
            name: "   ",
            format: ProjectFormat(),
            targetDuration: nil
        )

        #expect(values.applying(to: TrimatoProject()).name == "Untitled Project")
    }

    @Test func recentProjectsKeepSystemOrderAndExcludeUnavailableFiles() {
        let first = URL(fileURLWithPath: "/projects/First.trimato")
        let missing = URL(fileURLWithPath: "/projects/Missing.trimato")
        let movie = URL(fileURLWithPath: "/projects/Source.mov")
        let second = URL(fileURLWithPath: "/projects/Second.TRIMATO")
        let availablePaths = Set([first.path, movie.path, second.path])

        let result = ProjectLauncherRecentProjects.available(
            from: [first, missing, movie, second],
            fileExists: { availablePaths.contains($0) }
        )

        #expect(result == [first, second])
    }

    @Test func recentProjectsAreUniqueAndLimitedToEight() {
        let projects = (1...10).map {
            URL(fileURLWithPath: "/projects/Project \($0).trimato")
        }

        let result = ProjectLauncherRecentProjects.available(
            from: [projects[0], projects[0]] + projects,
            fileExists: { _ in true }
        )

        #expect(result.count == 8)
        #expect(result == Array(projects.prefix(8)))
    }

    @Test func recentProjectButtonsUseTheProjectNameWithoutItsPathOrExtension() {
        let url = URL(fileURLWithPath: "/Users/editor/Movies/Interview Cut.trimato")

        #expect(ProjectLauncherRecentProjects.displayName(for: url) == "Interview Cut")
    }

    @Test @MainActor func newProjectPanelUsesItsDirectNativeNextButtonAsTheDefault() {
        let hostingController = NSViewController()
        hostingController.view = NSView()
        let viewController = ProjectCreationPanelViewController(
            hostingController: hostingController,
            cancel: {},
            proceed: {}
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 610),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = viewController

        ProjectCreationWindowConfiguration.configureDefaultButton(
            viewController.nextButton,
            in: panel
        )

        #expect(panel.defaultButtonCell === viewController.nextButton.cell)
        #expect(viewController.nextButton.keyEquivalent == "\r")
        #expect(viewController.nextButton.window === panel)
        #expect(viewController.nextButton.superview === panel.contentView)
    }
}
