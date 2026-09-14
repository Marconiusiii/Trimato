import AppKit
import Foundation
import Darwin
@testable import Trimato

/// Does not create an application, a window, a player, or a recording session.
@main struct CaptionHelpCheck {
    static func verify(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL: \(message)"); exit(1) }
    }

    @MainActor static func main() throws {
        verify(NSApp == nil, "Application was already created")
        let project = TrimatoProject(name: "Caption request check")
        let controller = ProjectController(document: ProjectDocument(project: project))
        var opened = false
        controller.installCaptionEditorActions(open: { opened = true }, close: {})
        verify(controller.canRequestCaption, "Missing markers disabled the caption command")
        verify(!controller.canCreateCaption, "Missing markers permitted caption creation")
        controller.requestCaptionEditor()
        verify(!opened, "Caption editor opened without a range")
        verify(controller.presentedError?.title == "Caption Needs In and Out Points", "Missing marker error was not presented")
        verify(controller.presentedError?.message.contains("press I") == true, "Error omits marker instructions")
        verify(controller.project == project, "Invalid caption request changed the project")
        controller.presentedError = nil
        controller.isImporting = true
        verify(!controller.canRequestCaption, "Importing did not disable the command")
        controller.requestCaptionEditor()
        verify(!opened && controller.presentedError == nil, "Busy project reported a misleading marker error")
        controller.isImporting = false
        verify(controller.canRequestCaption, "Command did not recover after importing")

        guard CommandLine.arguments.count == 2,
              let application = Bundle(path: CommandLine.arguments[1]) else {
            print("FAIL: Provide the built Trimato.app path"); exit(1)
        }
        for topic in TrimatoHelp.Topic.allCases {
            let destination = try TrimatoHelp.destination(for: topic, in: application)
            verify(FileManager.default.fileExists(atPath: destination.pageURL.path), "Help page is missing")
            var registered = false
            var requested = false
            let error = TrimatoHelp.open(topic, in: application, registerBook: { url in
                verify(url == application.bundleURL, "Registered the wrong application")
                registered = true
                return 0
            }, lookupAnchor: { book, anchor in
                verify(registered, "Anchor lookup preceded registration")
                verify(book == destination.bookIdentifier, "Lookup used a stale book identifier")
                verify(anchor == topic.rawValue, "Lookup used the wrong topic anchor")
                requested = true
                return 0
            })
            verify(error == nil && requested, "Validated topic did not reach anchor lookup")
        }
        let registrationError = TrimatoHelp.open(.captioner, in: application,
            registerBook: { _ in -1 }, lookupAnchor: { _, _ in
                verify(false, "Lookup continued after registration failed")
                return 0
            })
        verify(registrationError?.contains("register") == true, "Registration error was lost")
        let lookupError = TrimatoHelp.open(.captioner, in: application,
            registerBook: { _ in 0 }, lookupAnchor: { _, _ in -1 })
        verify(lookupError?.contains("open this Help topic") == true, "Anchor lookup error was lost")
        verify(try TrimatoHelp.destination(for: .describer, in: application).page == "describer.html", "Wrong Describer destination")
        verify(try TrimatoHelp.destination(for: .voicer, in: application).page == "voicer.html", "Wrong Voicer destination")
        verify(try TrimatoHelp.destination(for: .captioner, in: application).page == "captioner.html", "Wrong Captioner destination")
        verify(NSApp == nil, "Check created an application")
        print("PASS: caption guidance, bundled Help destinations, anchor request routing, registration failure, and lookup failure; no Help viewer was opened")
    }
}
