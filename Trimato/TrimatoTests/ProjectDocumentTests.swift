import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Trimato

struct ProjectDocumentTests {
    @Test func trackMuteRoundTripsAndOlderTracksDefaultToUnmuted() throws {
        var project = TrimatoProject()
        let id = project.createTrack(kind: .audio, name: "Music")
        project.tracks[0].isMuted = true
        let encoded = try ProjectDocument.manifestData(for: project)
        let decoded = try JSONDecoder().decode(TrimatoProject.self, from: encoded)
        #expect(decoded.track(id: id)?.isMuted == true)
        var manifest = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var tracks = try #require(manifest["tracks"] as? [[String: Any]])
        tracks[0].removeValue(forKey: "isMuted")
        manifest["tracks"] = tracks
        let oldData = try JSONSerialization.data(withJSONObject: manifest)
        let oldProject = try JSONDecoder().decode(TrimatoProject.self, from: oldData)
        #expect(oldProject.track(id: id)?.isMuted == false)
    }

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

    @Test @MainActor func newProjectCreationWritesANamedFolderContainingTheSavedPackage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrimatoNewProject-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Interview Cut", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var project = TrimatoProject(name: "Draft Name")
        project.targetDuration = ProjectTime(seconds: 90)
        let packageURL = try ProjectDocument.writeNewProject(project, toFolderAt: folder)

        #expect(packageURL == folder.appendingPathComponent("Interview Cut.trimato", isDirectory: true))
        #expect(FileManager.default.fileExists(atPath: packageURL.path))
        let package = try FileWrapper(url: packageURL, options: .immediate)
        let decoded = try ProjectDocument.decodeProject(from: package)
        #expect(decoded.name == "Interview Cut")
        #expect(decoded.targetDuration == ProjectTime(seconds: 90))
    }

    @Test @MainActor func newProjectCreationDoesNotOverwriteAnExistingFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrimatoExistingProject-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Existing", isDirectory: true)
        let marker = folder.appendingPathComponent("keep.txt")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: marker)

        #expect(throws: CocoaError.self) {
            try ProjectDocument.writeNewProject(TrimatoProject(), toFolderAt: folder)
        }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "keep")
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
        #expect(decoded.schemaVersion == TrimatoProject.currentSchemaVersion)
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

    @Test func transitionNamesAndBundleIdentityPersistInTheProjectManifest() throws {
        let asset = fixtureAsset(name: "Interview", duration: 12)
        var project = TrimatoProject(name: "Named Transition")
        project.media = [asset]
        let leadingID = try project.append(asset: asset, segments: [SourceSegment(sourceRange: ProjectTimeRange(
            start: ProjectTime(seconds: 1),
            duration: ProjectTime(seconds: 3)
        ))])
        let trailingID = try project.append(asset: asset, segments: [SourceSegment(sourceRange: ProjectTimeRange(
            start: ProjectTime(seconds: 7),
            duration: ProjectTime(seconds: 3)
        ))])
        let track = try #require(project.tracks.first { $0.role == .primaryVideo })
        let bundleID = UUID()
        project.transitions = [TimelineTransition(
            bundleID: bundleID,
            trackID: track.id,
            edge: .between,
            kind: .video(.crossDissolve),
            duration: ProjectTime(seconds: 1),
            leadingClipID: leadingID,
            trailingClipID: trailingID,
            customName: "Courtyard Blend"
        )]

        let data = try ProjectDocument.manifestData(for: project)
        let decoded = try JSONDecoder().decode(TrimatoProject.self, from: data)
        let transition = try #require(decoded.transitions.first)

        #expect(transition.bundleID == bundleID)
        #expect(transition.customName == "Courtyard Blend")
        #expect(transition.displayName == "Courtyard Blend")
    }

    @Test func transitionsSavedBeforeNamesAndBundlesRemainReadable() throws {
        let transition = TimelineTransition(
            trackID: UUID(),
            edge: .between,
            kind: .video(.crossDissolve),
            duration: ProjectTime(seconds: 1),
            leadingClipID: UUID(),
            trailingClipID: UUID()
        )
        let encoded = try JSONEncoder().encode(transition)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "bundleID")
        object.removeValue(forKey: "customName")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(TimelineTransition.self, from: legacyData)

        #expect(decoded.bundleID == nil)
        #expect(decoded.customName == nil)
        #expect(decoded.displayName == "Cross Dissolve")
    }
}
