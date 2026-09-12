import Foundation
import Darwin

/// A process holds an advisory lock for as long as its previews may use these files.
/// Normal callers still delete outputs promptly; a later session reclaims crash leftovers.
nonisolated final class TemporaryMediaSession: @unchecked Sendable {
    let directory: URL
    private let owner: Int32

    init(root: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        Self.removeAbandoned(in: root)
        directory = root.appendingPathComponent("session-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        owner = open(directory.appendingPathComponent("owner.lock").path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
        guard owner >= 0 else {
            try? manager.removeItem(at: directory)
            throw CocoaError(.fileWriteUnknown)
        }
        guard flock(owner, LOCK_EX | LOCK_NB) == 0 else {
            close(owner)
            try? manager.removeItem(at: directory)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    deinit { close(owner) }

    static func removeAbandoned(in root: URL, before cutoff: Date = Date().addingTimeInterval(-86400)) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return }
        for entry in entries {
            guard entry.lastPathComponent.hasPrefix("session-"),
                  UUID(uuidString: String(entry.lastPathComponent.dropFirst(8))) != nil,
                  let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let lockURL = entry.appendingPathComponent("owner.lock")
            guard let modified = try? lockURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < cutoff else { continue }
            let descriptor = open(lockURL.path, O_RDWR | O_NOFOLLOW)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            // Failure to acquire the lock means another process still owns the media.
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { continue }
            try? manager.removeItem(at: entry)
        }
    }

    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var session: TemporaryMediaSession?
    }
    private static let storage = Storage()

    static func directory(named name: String) throws -> URL {
        try storage.lock.withLock {
            if storage.session == nil {
                storage.session = try TemporaryMediaSession(root: FileManager.default.temporaryDirectory
                    .appendingPathComponent("TrimatoOwnedMedia", isDirectory: true))
            }
            let directory = storage.session!.directory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
    }
}
