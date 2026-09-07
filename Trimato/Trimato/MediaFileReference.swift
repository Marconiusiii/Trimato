import Foundation

/// A project-relative path takes precedence after the whole project folder moves.
nonisolated struct MediaFileReference: Codable, Equatable, Sendable {
    var originalPath: String
    var bookmarkData: Data?
    var projectRelativePath: String?

    static func relativePath(for url: URL, in folder: URL) -> String? {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard path.hasPrefix(root) else { return nil }
        return String(path.dropFirst(root.count))
    }

    static func relativeURL(_ relative: String?, folder: URL?) -> URL? {
        guard let relative, !relative.isEmpty, !relative.hasPrefix("/"),
              !relative.split(separator: "/").contains(".."), let folder else { return nil }
        let candidate = folder.appendingPathComponent(relative)
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard candidate.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else { return nil }
        return candidate
    }

    func resolve(folder: URL?, folderBookmark: Data? = nil) -> URL? {
        var staleFolder = false
        let grantedFolder = folderBookmark.flatMap {
            try? URL(resolvingBookmarkData: $0, options: [.withSecurityScope, .withoutUI],
                     relativeTo: nil, bookmarkDataIsStale: &staleFolder)
        }
        let hasFolderAccess = grantedFolder?.standardizedFileURL == folder?.standardizedFileURL
            && grantedFolder?.startAccessingSecurityScopedResource() == true
        defer { if hasFolderAccess { grantedFolder?.stopAccessingSecurityScopedResource() } }
        let relative = Self.relativeURL(projectRelativePath, folder: folder)
        var stale = false
        let bookmark = bookmarkData.flatMap {
            try? URL(resolvingBookmarkData: $0, options: [.withSecurityScope, .withoutUI],
                     relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        for url in [relative, bookmark, URL(fileURLWithPath: originalPath)].compactMap({ $0 }) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if FileManager.default.isReadableFile(atPath: url.path),
               (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { return url }
        }
        return nil
    }
}
