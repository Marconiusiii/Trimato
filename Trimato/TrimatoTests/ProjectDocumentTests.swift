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

    @Test func decodedProjectProvidesACleanExplicitSaveBaseline() throws {
        let original = TrimatoProject(name: "Saved Project")
        let manifest = try ProjectDocument.manifestData(for: original)
        let package = FileWrapper(directoryWithFileWrappers: [
            "project.json": FileWrapper(regularFileWithContents: manifest)
        ])
        let document = ProjectDocument(project: try ProjectDocument.decodeProject(from: package))

        #expect(document.project == original)
        #expect(!document.hasUnsavedChanges)
    }

    @Test func legacyRegularFileProjectsRemainReadable() throws {
        let project = TrimatoProject(name: "Legacy Project")
        let manifest = try ProjectDocument.manifestData(for: project)
        let file = FileWrapper(regularFileWithContents: manifest)

        let decoded = try ProjectDocument.decodeProject(from: file)

        #expect(decoded.name == "Legacy Project")
    }

    @Test func reopenedAutomaticProjectsNormalizeUnstableSavedFrameRates() throws {
        var project = TrimatoProject(name: "Variable frame rate project")
        project.format = ProjectFormat(
            mode: .automatic,
            width: 1_536,
            height: 2_048,
            frameRate: 30.004427
        )
        let manifest = try ProjectDocument.manifestData(for: project)
        let decoded = try JSONDecoder().decode(TrimatoProject.self, from: manifest)

        #expect(decoded.format.frameRate == 30)
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
          "primaryTimeline": [{
            "id": "00000000-0000-0000-0000-000000000004",
            "assetID": "00000000-0000-0000-0000-000000000002",
            "name": "Interview",
            "segments": [{
              "id": "00000000-0000-0000-0000-000000000005",
              "sourceRange": {
                "start": { "value": 0, "timescale": 600000 },
                "duration": { "value": 6000000, "timescale": 600000 }
              }
            }]
          }],
          "cutaways": []
        }
        """

        let decoded = try JSONDecoder().decode(TrimatoProject.self, from: Data(json.utf8))

        #expect(decoded.media.first?.playbackMode == nil)
        #expect(decoded.media.first?.proxyCacheKey == nil)
        #expect(decoded.media.first?.sourceFingerprint == nil)
        #expect(decoded.primaryTimeline.first?.labelOrdinal == nil)
        #expect(decoded.primaryTimeline.first?.customName == nil)
        #expect(decoded.primaryTimeline.first?.displayName == "Interview")
        #expect(decoded.schemaVersion == 2)
        #expect(decoded.tracks.first(where: { $0.role == .primaryVideo })?.clips.count == 1)
        #expect(decoded.tracks.first(where: { $0.role == .primaryAudio })?.clips.first?.displayName == "Interview Audio")
    }

    @Test func customTimelineNamesPersistInTheProjectManifest() throws {
        let asset = fixtureAsset(name: "Interview", duration: 5)
        var project = TrimatoProject(name: "Renamed Project")
        project.media = [asset]
        let clipID = try project.append(asset: asset)
        try project.renameTimelineClip(id: clipID, to: "Opening")

        let data = try ProjectDocument.manifestData(for: project)
        let decoded = try JSONDecoder().decode(TrimatoProject.self, from: data)

        #expect(decoded.primaryTimeline.first?.customName == "Opening")
        #expect(decoded.primaryTimeline.first?.displayName == "Opening")
    }
}
