import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Trimato

struct ProjectDocumentTests {
    @Test func projectDocumentWritesAVersionedPackageManifest() throws {
        let project = TrimatoProject(name: "Saved Project")
        let manifest = try ProjectDocument.manifestData(for: project)
        let package = FileWrapper(directoryWithFileWrappers: [
            "project.json": FileWrapper(regularFileWithContents: manifest)
        ])

        let decoded = try ProjectDocument.decodeProject(from: package)

        #expect(decoded.name == "Saved Project")
        #expect(decoded.schemaVersion == TrimatoProject.currentSchemaVersion)
    }

    @Test func legacyRegularFileProjectsRemainReadable() throws {
        let project = TrimatoProject(name: "Legacy Project")
        let manifest = try ProjectDocument.manifestData(for: project)
        let file = FileWrapper(regularFileWithContents: manifest)

        let decoded = try ProjectDocument.decodeProject(from: file)

        #expect(decoded.name == "Legacy Project")
    }

    @Test func trimatoTypeUsesTheProjectExtensionAndPackageSemantics() {
        #expect(UTType.trimatoProject.preferredFilenameExtension == "trimato")
        #expect(UTType.trimatoProject.conforms(to: .package))
    }
}
