import AppKit
import Foundation
import UniformTypeIdentifiers
@testable import Trimato

@main struct MediaSelectionCheck {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("trimato-media-selection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let extensions = ["MOV", "mp4", "m4a", "wav", "aiff", "mp3", "flac"] + MediaSelection.additionalExtensions
        var accepted: [URL] = []
        for ext in extensions {
            let url = root.appendingPathComponent("Fixture.\(ext)")
            try Data().write(to: url)
            check(MediaSelection.isSupportedMedia(url), "Media rejected: \(ext)")
            check(ExternalMediaOpenCoordinator.route(for: url, hasActiveProject: false) == .standaloneEditor, "Finder policy disagrees")
            let imported = try ProjectImportCoordinator.importableMediaURLs(in: url)
            check(imported == [url], "Import policy disagrees")
            let type = UTType(filenameExtension: ext)!
            check(MediaSelection.mediaTypes.contains { type.conforms(to: $0) }, "Picker omits \(ext)")
            accepted.append(url)
        }
        var captions: [URL] = []
        for ext in ["srt", "vtt", "pdf", "txt", "png", "zip", "trimato"] {
            let url = root.appendingPathComponent("Other.\(ext)")
            try Data().write(to: url)
            check(!MediaSelection.isSupportedMedia(url), "Unrelated file accepted: \(ext)")
            check(ExternalMediaOpenCoordinator.route(for: url, hasActiveProject: false) == .ignore, "Finder accepts unrelated file")
            let imported = try ProjectImportCoordinator.importableMediaURLs(in: url)
            check(imported.isEmpty, "Import accepts unrelated media")
            if ["srt", "vtt"].contains(ext) {
                captions.append(url)
                let importedCaptions = try ProjectImportCoordinator.importableCaptionURLs(in: url)
                check(importedCaptions == [url], "Caption support lost")
            }
        }
        var hidden = root.appendingPathComponent("Hidden extension.mov")
        try Data().write(to: hidden)
        var resources = URLResourceValues()
        resources.hasHiddenExtension = true
        try hidden.setResourceValues(resources)
        check(MediaSelection.isSupportedMedia(hidden), "Hidden extension changed selection")
        accepted.append(hidden)
        let reference = (hidden as NSURL).fileReferenceURL()! as URL
        check(MediaSelection.isSupportedMedia(reference), "File reference URL rejected")
        let nested = root.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedMedia = nested.appendingPathComponent("Sound.wav")
        try Data().write(to: nestedMedia)
        accepted.append(nestedMedia)
        let package = root.appendingPathComponent("Project.trimato")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data().write(to: package.appendingPathComponent("Internal.mov"))
        check(!MediaSelection.isSupportedMedia(package), "Project accepted as media")
        let packageMedia = try ProjectImportCoordinator.importableMediaURLs(in: package)
        check(packageMedia.isEmpty, "Selected project traversed as an import folder")
        let imported = try ProjectImportCoordinator.importableMediaURLs(in: root)
        func paths(_ urls: [URL]) -> Set<String> {
            Set(urls.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        }
        check(paths(imported) == paths(accepted), "Recursive folder media selection changed")
        let importedCaptions = try ProjectImportCoordinator.importableCaptionURLs(in: root)
        check(paths(importedCaptions) == paths(captions), "Recursive folder caption selection changed")
        check(!MediaSelection.isSupportedMedia(URL(string: "https://example.com/movie.mov")!), "Remote URL accepted")

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        for importing in [false, true] {
            let panel = NSOpenPanel()
            MediaSelection.configure(panel, importing: importing)
            check(!panel.allowedContentTypes.contains(.data), "Broad data filter remains")
            check(panel.canChooseFiles && panel.canChooseDirectories == importing, "Wrong folder policy")
            check(panel.allowsMultipleSelection == importing, "Wrong selection count")
            check(panel.resolvesAliases && !panel.treatsFilePackagesAsDirectories, "Native alias/package behavior changed")
            check(panel.allowedContentTypes.contains(.subRipCaption) == importing, "Caption picker mismatch")
            check(!panel.isVisible, "Panel was displayed")
        }
        print("PASS: media/Finder/import agreement, eight extra formats, hidden extensions, file reference URLs, caption and recursive folder import, unrelated-file and project rejection, native unshown panel configuration")
    }
}
