import Foundation
import Testing
@testable import TrimatoMediaSupport

struct TemporaryMediaSessionTests {
    @Test func cleanupProtectsAnOldActiveSessionAndReclaimsItAfterRelease() throws {
        let root = try MediaFileTransferTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var session: TemporaryMediaSession? = try TemporaryMediaSession(root: root)
        let directory = try #require(session?.directory)
        let media = directory.appendingPathComponent("preview.mov")
        try Data("preview".utf8).write(to: media)
        let cutoff = Date().addingTimeInterval(1)
        TemporaryMediaSession.removeAbandoned(in: root, before: cutoff)
        #expect(FileManager.default.fileExists(atPath: media.path))
        session = nil
        TemporaryMediaSession.removeAbandoned(in: root, before: cutoff)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func cleanupLeavesUnownedFilesAndSymlinksAlone() throws {
        let root = try MediaFileTransferTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try MediaFileTransferTests().fixture()
        defer { try? FileManager.default.removeItem(at: outside) }
        let original = root.appendingPathComponent("original.mov")
        try Data("original".utf8).write(to: original)
        let link = root.appendingPathComponent("session-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        TemporaryMediaSession.removeAbandoned(in: root, before: .distantFuture)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }
}
