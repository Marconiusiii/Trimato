import Foundation
import Testing
@testable import TrimatoMediaSupport

struct MediaFileReferenceTests {
    @Test func relativeReferenceSurvivesMovingTheProjectFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Project")
        let clips = old.appendingPathComponent("Clips")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        let source = clips.appendingPathComponent("voice.wav")
        try Data("audio".utf8).write(to: source)
        let reference = MediaFileReference(originalPath: source.path, bookmarkData: nil, projectRelativePath: "Clips/voice.wav")
        let saved = try JSONEncoder().encode(reference)
        let moved = root.appendingPathComponent("Moved Project")
        try FileManager.default.moveItem(at: old, to: moved)
        let reopened = try JSONDecoder().decode(MediaFileReference.self, from: saved)
        #expect(reopened.resolve(folder: moved)?.standardizedFileURL == moved.appendingPathComponent("Clips/voice.wav").standardizedFileURL)
    }

    @Test func missingReferenceRecoversWhenMediaReturns() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("voice.wav")
        let reference = MediaFileReference(originalPath: source.path, bookmarkData: nil, projectRelativePath: nil)
        #expect(reference.resolve(folder: nil) == nil)
        try Data("audio".utf8).write(to: source)
        #expect(reference.resolve(folder: nil) == source)
        try FileManager.default.removeItem(at: source)
        #expect(reference.resolve(folder: nil) == nil)
    }

    @Test func relativePathsCannotEscapeProjectFolder() {
        let root = URL(fileURLWithPath: "/tmp/project")
        #expect(MediaFileReference.relativeURL("../outside.wav", folder: root) == nil)
        #expect(MediaFileReference.relativeURL("/outside.wav", folder: root) == nil)
        #expect(MediaFileReference.relativeURL("", folder: root) == nil)
    }

    @Test func fileHandlingDefaultsToKeepingOriginalsAndPersistsChoice() throws {
        let name = "MediaPreferences.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(ImportedFileHandling.preference(in: defaults) == .keep)
        defaults.set("invalid", forKey: ImportedFileHandling.preferenceKey)
        #expect(ImportedFileHandling.preference(in: defaults) == .keep)
        defaults.set("move", forKey: ImportedFileHandling.preferenceKey)
        #expect(ImportedFileHandling.preference(in: defaults) == .move)
    }
}
