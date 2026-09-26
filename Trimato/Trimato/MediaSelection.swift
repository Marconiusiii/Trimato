import AppKit
import Foundation
import UniformTypeIdentifiers

/// File selection is shared; decoding still determines whether a particular
/// file is readable. Extra extensions preserve Trimato's FFmpeg import support.
nonisolated enum MediaSelection {
    static let additionalExtensions = ["mkv", "webm", "ts", "mts", "m2ts", "vob", "wmv", "flv"]

    static var mediaTypes: [UTType] {
        [.movie, .audio] + additionalExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    static func isSupportedMedia(_ url: URL, contentType: UTType? = nil) -> Bool {
        guard url.isFileURL, url.pathExtension.lowercased() != "trimato" else { return false }
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .nameKey, .isDirectoryKey])
        guard values?.isDirectory != true else { return false }
        let resourceExtension = values?.name.map { ($0 as NSString).pathExtension }
        let ext = resourceExtension.flatMap { $0.isEmpty ? nil : $0 } ?? url.pathExtension
        if additionalExtensions.contains(ext.lowercased()) { return true }
        let types = [contentType, values?.contentType, UTType(filenameExtension: ext)].compactMap { $0 }
        return types.contains { $0.conforms(to: .movie) || $0.conforms(to: .audio) }
    }

    @MainActor static func configure(_ panel: NSOpenPanel, importing: Bool = false) {
        panel.allowedContentTypes = mediaTypes + (importing ? [.subRipCaption, .webVTTCaption, .folder] : [])
        panel.treatsFilePackagesAsDirectories = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = importing
        panel.allowsMultipleSelection = importing
        panel.resolvesAliases = true
    }
}
