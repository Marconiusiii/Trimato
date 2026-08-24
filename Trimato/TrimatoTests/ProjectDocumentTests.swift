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

    @Test func projectsWrittenBeforePlaybackPreparationRemainReadable() throws {
        let json = """
        {
          "schemaVersion": 1,
          "id": "00000000-0000-0000-0000-000000000001",
          "name": "Earlier Project",
          "format": { "mode": "automatic" },
          "folders": [],
          "media": [{
            "id": "00000000-0000-0000-0000-000000000002",
            "name": "Interview",
            "originalPath": "/tmp/Interview.mov",
            "duration": { "value": 6000000, "timescale": 600000 },
            "naturalWidth": 1920,
            "naturalHeight": 1080,
            "frameRate": 30,
            "hasAudio": true,
            "sourceEdit": [{
              "id": "00000000-0000-0000-0000-000000000003",
              "sourceRange": {
                "start": { "value": 0, "timescale": 600000 },
                "duration": { "value": 6000000, "timescale": 600000 }
              }
            }]
          }],
          "primaryTimeline": [],
          "cutaways": []
        }
        """

        let decoded = try JSONDecoder().decode(TrimatoProject.self, from: Data(json.utf8))

        #expect(decoded.media.first?.playbackMode == nil)
        #expect(decoded.media.first?.proxyCacheKey == nil)
    }
}
