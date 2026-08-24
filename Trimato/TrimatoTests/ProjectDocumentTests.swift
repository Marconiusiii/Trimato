import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Trimato

struct ProjectDocumentTests {
    @Test func projectDocumentWritesAVersionedPackageManifest() throws {
        let project = TrimatoProject(name: "Saved Project")
        let manifest = try ProjectDocument.manifestData(for: project)
        let decoded = try JSONDecoder().decode(TrimatoProject.self, from: manifest)

        #expect(decoded.name == "Saved Project")
        #expect(decoded.schemaVersion == TrimatoProject.currentSchemaVersion)
    }

    @Test func trimatoTypeUsesTheProjectExtensionAndPackageSemantics() {
        #expect(UTType.trimatoProject.preferredFilenameExtension == "trimato")
        #expect(UTType.trimatoProject.conforms(to: .package))
    }
}
