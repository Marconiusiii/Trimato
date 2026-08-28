import Foundation
import Testing
@testable import Trimato

@Suite("Project import discovery")
struct ProjectImportCoordinatorTests {
    @Test func recursivelyFindsSupportedMediaAndSkipsOtherFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrimatoImport-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data().write(to: root.appendingPathComponent("Interview.mov"))
        try Data().write(to: nested.appendingPathComponent("Narration.wav"))
        try Data().write(to: nested.appendingPathComponent("Notes.txt"))

        let discovered = try ProjectImportCoordinator.importableMediaURLs(in: root)

        #expect(discovered.map(\.lastPathComponent) == ["Interview.mov", "Narration.wav"])
    }

    @Test func returnsOneSupportedFileOrNoUnsupportedFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrimatoImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("Walk.mkv")
        let text = root.appendingPathComponent("Notes.txt")
        try Data().write(to: movie)
        try Data().write(to: text)

        #expect(try ProjectImportCoordinator.importableMediaURLs(in: movie) == [movie])
        #expect(try ProjectImportCoordinator.importableMediaURLs(in: text).isEmpty)
    }
}
