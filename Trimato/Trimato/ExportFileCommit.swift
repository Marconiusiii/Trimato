import Foundation

/// The caller owns the staging directory until this synchronous commit succeeds.
/// No suspension is allowed between the cancellation check and replacement.
nonisolated enum ExportFileCommit {
    static func protectSources(_ sources: [URL], destination: URL) throws {
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        let targetAttributes = try? FileManager.default.attributesOfItem(atPath: target.path)
        for source in sources {
            let original = source.resolvingSymlinksInPath().standardizedFileURL
            let attributes = try? FileManager.default.attributesOfItem(atPath: original.path)
            let sameFile = targetAttributes?[.systemNumber] as? NSNumber == attributes?[.systemNumber] as? NSNumber
                && targetAttributes?[.systemFileNumber] as? NSNumber == attributes?[.systemFileNumber] as? NSNumber
                && targetAttributes?[.systemFileNumber] != nil
            if original == target || sameFile {
                throw MediaFileHandlingError(message: "Choose a different export filename. This destination is an original source file used by the edit.")
            }
        }
    }

    static func commit(_ staged: URL, to destination: URL) throws {
        try Task.checkCancellation()
        var staged = staged
        var destination = destination
        staged.removeAllCachedResourceValues()
        destination.removeAllCachedResourceValues()
        let values = try staged.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? 0) > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let manager = FileManager.default
        // Never replace a directory or follow a destination symlink.
        if let existing = try? destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
           existing.isDirectory == true || existing.isSymbolicLink == true {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try Task.checkCancellation()
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try manager.moveItem(at: staged, to: destination)
        }
    }
}
