import Foundation
import Testing
@testable import TrimatoMediaSupport

struct ExportFileCommitTests {
    @Test func originalProtectionRecognizesHardLinksAndSymbolicLinks() throws {
        let root = try MediaFileTransferTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.wav")
        let hard = root.appendingPathComponent("hard.wav"), symbolic = root.appendingPathComponent("symbolic.wav")
        try Data("original".utf8).write(to: original)
        try FileManager.default.linkItem(at: original, to: hard)
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: original)
        for destination in [original, hard, symbolic] {
            #expect(throws: MediaFileHandlingError.self) {
                try ExportFileCommit.protectSources([original], destination: destination)
            }
        }
        try ExportFileCommit.protectSources([original], destination: root.appendingPathComponent("new.wav"))
        #expect(try Data(contentsOf: original) == Data("original".utf8))
    }

    @Test func invalidOrCancelledOutputPreservesExistingFile() async throws {
        let root = try MediaFileTransferTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = root.appendingPathComponent("staged.wav"), destination = root.appendingPathComponent("saved.wav")
        try Data("saved".utf8).write(to: destination)
        try Data().write(to: staged)
        #expect(throws: (any Error).self) { try ExportFileCommit.commit(staged, to: destination) }
        #expect(try Data(contentsOf: destination) == Data("saved".utf8))
        try Data("new".utf8).write(to: staged)
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try ExportFileCommit.commit(staged, to: destination)
        }
        do { try await work.value; Issue.record("Cancelled output committed") } catch is CancellationError { }
        #expect(try Data(contentsOf: destination) == Data("saved".utf8))
        #expect(try Data(contentsOf: staged) == Data("new".utf8))
        try ExportFileCommit.commit(staged, to: destination)
        #expect(try Data(contentsOf: destination) == Data("new".utf8))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test func failedDestinationDoesNotConsumeStagingOrOverwriteDirectory() throws {
        let root = try MediaFileTransferTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = root.appendingPathComponent("staged.wav")
        try Data("new".utf8).write(to: staged)
        let missing = root.appendingPathComponent("missing/output.wav")
        #expect(throws: (any Error).self) { try ExportFileCommit.commit(staged, to: missing) }
        #expect(throws: (any Error).self) { try ExportFileCommit.commit(staged, to: root) }
        let link = root.appendingPathComponent("link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: staged)
        #expect(throws: (any Error).self) { try ExportFileCommit.commit(staged, to: link) }
        #expect(try Data(contentsOf: staged) == Data("new".utf8))
    }
}
