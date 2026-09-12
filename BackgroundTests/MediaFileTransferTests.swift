import Foundation
import Testing
@testable import TrimatoMediaSupport

struct MediaFileTransferTests {
    @Test func sourceChangedDuringVerificationRollsBackTheCopy() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav"), clips = root.appendingPathComponent("Clips")
        try Data("original".utf8).write(to: source)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        await #expect(throws: MediaFileHandlingError.self) {
            _ = try await MediaFileTransfer.prepare([UUID(): source], in: clips) { update in
                if update.detail.hasPrefix("Verifying") { try? Data("changed".utf8).write(to: source) }
            }
        }
        #expect(try Data(contentsOf: source) == Data("changed".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: clips.path).isEmpty)
    }

    @Test func missingVerifiedCopyPreventsOriginalRemoval() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav"), clips = root.appendingPathComponent("Clips")
        try Data("original".utf8).write(to: source)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        let result = try await MediaFileTransfer.prepare([UUID(): source], in: clips, progress: { _ in })
        try FileManager.default.removeItem(at: result.created[0])
        #expect(await MediaFileTransfer.removeOriginals(result).count == 1)
        #expect(try Data(contentsOf: source) == Data("original".utf8))
    }

    @Test func cancelledRemovalReportsEveryRetainedOriginal() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        let copy = root.appendingPathComponent("copy.wav")
        try Data("audio".utf8).write(to: source)
        try FileManager.default.copyItem(at: source, to: copy)
        let transfer = MediaTransferResult(destinations: [:], created: [copy], originals: [source], removals: [source: copy])
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await MediaFileTransfer.removeOriginals(transfer)
        }
        #expect(await work.value.count == 1)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: copy) == Data("audio".utf8))
    }

    func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func copiesOnceForDuplicateReferencesAndDoesNotOverwriteNames() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("voice.wav")
        try Data("source".utf8).write(to: source)
        let clips = root.appendingPathComponent("Clips")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: clips.appendingPathComponent("voice.wav"))
        let first = UUID(), second = UUID()
        let result = try await MediaFileTransfer.prepare([first: source, second: source], in: clips, progress: { _ in })
        #expect(result.created.count == 1)
        #expect(result.destinations[first] == result.destinations[second])
        #expect(try Data(contentsOf: clips.appendingPathComponent("voice.wav")) == Data("existing".utf8))
        #expect(try Data(contentsOf: result.destinations[first]!) == Data("source".utf8))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func unavailableSourceLeavesNoPartialFiles() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await MediaFileTransfer.prepare([UUID(): root.appendingPathComponent("missing.wav")], in: root, progress: { _ in })
            Issue.record("Missing source was accepted")
        } catch { }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func filesAlreadyInClipsAreNotCopiedOrScheduledForRemoval() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("voice.wav")
        try Data("source".utf8).write(to: source)
        let id = UUID()
        let result = try await MediaFileTransfer.prepare([id: source], in: root, progress: { _ in })
        #expect(result.destinations[id] == source)
        #expect(result.created.isEmpty)
        #expect(result.originals.isEmpty)
    }

    @Test func cancelledOperationKeepsOriginalAndRemovesTemporaryFiles() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("voice.wav")
        try Data(repeating: 7, count: 8_000_000).write(to: source)
        let clips = root.appendingPathComponent("Clips")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        let started = AsyncStream<Void>.makeStream()
        let resume = DispatchSemaphore(value: 0)
        let work = Task {
            return try await MediaFileTransfer.prepare([UUID(): source], in: clips, progress: { update in
                if update.detail.hasPrefix("Copying") {
                    started.continuation.yield()
                    resume.wait()
                }
            })
        }
        var events = started.stream.makeAsyncIterator()
        _ = await events.next()
        work.cancel()
        resume.signal()
        do { _ = try await work.value; Issue.record("Cancellation was ignored") } catch is CancellationError { }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: clips.path).isEmpty)
    }

    @Test func moveCleanupRemovesOnlyVerifiedOriginals() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("voice.wav")
        try Data("original".utf8).write(to: source)
        let clips = root.appendingPathComponent("Clips")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        let result = try await MediaFileTransfer.prepare([UUID(): source], in: clips, progress: { _ in })
        #expect(await MediaFileTransfer.removeOriginals(result).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: result.created[0]) == Data("original".utf8))
    }

    @Test func changedOriginalIsKeptDuringMoveCleanup() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("voice.wav")
        try Data("first".utf8).write(to: source)
        let clips = root.appendingPathComponent("Clips")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        let result = try await MediaFileTransfer.prepare([UUID(): source], in: clips, progress: { _ in })
        try Data("changed".utf8).write(to: source)
        let failures = await MediaFileTransfer.removeOriginals(result)
        #expect(failures.count == 1)
        #expect(try Data(contentsOf: source) == Data("changed".utf8))
        #expect(try Data(contentsOf: result.created[0]) == Data("first".utf8))
    }

    @Test func laterFailureRollsBackEarlierCopies() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("voice.wav")
        try Data("original".utf8).write(to: source)
        let clips = root.appendingPathComponent("Clips")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        do {
            _ = try await MediaFileTransfer.prepare([first: source, second: root.appendingPathComponent("missing.wav")], in: clips, progress: { _ in })
            Issue.record("Missing source accepted")
        } catch { }
        #expect(try FileManager.default.contentsOfDirectory(atPath: clips.path).isEmpty)
        #expect(try Data(contentsOf: source) == Data("original".utf8))
    }

    @Test func symbolicSourcesBecomeRealProjectFiles() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.wav")
        try Data("audio".utf8).write(to: source)
        let link = root.appendingPathComponent("linked.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let clips = root.appendingPathComponent("Clips")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        let id = UUID()
        let result = try await MediaFileTransfer.prepare([id: link], in: clips, progress: { _ in })
        let output = try #require(result.destinations[id])
        #expect(try output.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
        #expect(try Data(contentsOf: output) == Data("audio".utf8))
    }

    @Test func importedFileChoicesHaveConciseLabels() {
        #expect(ImportedFileHandling.allCases.map(\.title) == ["Keep in Place", "Move to Project", "Ask Each Time"])
    }
}
