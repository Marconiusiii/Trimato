import AppKit
import Foundation
import UniformTypeIdentifiers
@testable import Trimato

@main struct ProjectOpenFilterCheck {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trimato-open-filter-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let project = directory.appendingPathComponent("Example.trimato")
        let uppercase = directory.appendingPathComponent("Uppercase.TRIMATO")
        let folder = directory.appendingPathComponent("Media")
        let otherPackage = directory.appendingPathComponent("Other.app")
        for url in [project, uppercase, folder, otherPackage] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let movie = folder.appendingPathComponent("02_Coffee.MOV")
        let audio = folder.appendingPathComponent("Audio.wav")
        let text = folder.appendingPathComponent("Notes.txt")
        let misleading = folder.appendingPathComponent("Not a package.trimato")
        for url in [movie, audio, text, misleading] { try Data().write(to: url) }
        let link = directory.appendingPathComponent("Project link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: project)
        let alias = directory.appendingPathComponent("Project alias")
        try URL.writeBookmarkData(project.bookmarkData(options: .suitableForBookmarkFile), to: alias)
        let movieAlias = directory.appendingPathComponent("Movie alias")
        try URL.writeBookmarkData(movie.bookmarkData(options: .suitableForBookmarkFile), to: movieAlias)

        for url in [project, uppercase, alias, link] {
            check(ProjectOpenSelection.kind(of: url) == .project, "Project or alias rejected: \(url)")
            check(ProjectOpenPanel.shared.panel(0, shouldEnable: url), "Project disabled")
        }
        check(ProjectOpenSelection.kind(of: folder) == .folder, "Folder navigation rejected")
        check(ProjectOpenPanel.shared.panel(0, shouldEnable: folder), "Folder disabled")
        for url in [movie, audio, text, misleading, otherPackage, movieAlias,
                    directory.appendingPathComponent("Missing.trimato"), URL(string: "https://example.com/test.trimato")!] {
            check(ProjectOpenSelection.kind(of: url) == .other, "Invalid item accepted: \(url)")
            check(!ProjectOpenPanel.shared.panel(0, shouldEnable: url), "Invalid item enabled")
        }
        // An invalid project selection must return before consulting NSDocumentController
        // or attempting replacement of the current project.
        check(NSApp == nil, "Check unexpectedly created an application")
        let coordinator = SingleProjectCoordinator()
        var completions = 0
        coordinator.openDocument(at: movie) { completions += 1 }
        check(completions == 1 && coordinator.presentedError != nil, "Invalid open was not rejected")
        check(NSApp == nil, "Invalid selection entered document-opening machinery")

        let plistURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as! [String: Any]
        let exports = plist["UTExportedTypeDeclarations"] as! [[String: Any]]
        let declaration = exports.first { $0["UTTypeIdentifier"] as? String == "com.marconius.trimato.project" }!
        let tags = declaration["UTTypeTagSpecification"] as! [String: Any]
        check(tags["public.filename-extension"] as? [String] == ["trimato"], "Built extension declaration incorrect")
        check(declaration["UTTypeConformsTo"] as? [String] == ["com.apple.package"], "Built project conformance incorrect")
        check(!UTType.quickTimeMovie.conforms(to: .trimatoProject), "Movie registered as a project")

        // Inspect native configuration without displaying the panel or activating the app.
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let panel = ProjectOpenPanel.make()
        check(panel.allowedContentTypes == [.trimatoProject], "Native panel lost its type filter")
        check(panel.delegate === ProjectOpenPanel.shared, "Native delegate not retained")
        check(panel.canChooseFiles && !panel.canChooseDirectories, "Native selection configuration incorrect")
        check(!panel.treatsFilePackagesAsDirectories && !panel.allowsMultipleSelection, "Package configuration incorrect")
        check(!panel.isVisible, "Background check displayed a panel")
        print("PASS: built type declaration, native panel configuration, package and folder rules, movie/audio/document rejection, aliases, symlinks, and rejection before document replacement")
    }
}
