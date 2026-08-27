import Foundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

final class ProjectDocument: ReferenceFileDocument {
    typealias Snapshot = TrimatoProject

    static var readableContentTypes: [UTType] { [.trimatoProject] }
    static var writableContentTypes: [UTType] { [.trimatoProject] }

    let objectWillChange = ObservableObjectPublisher()
    private var storedProject: TrimatoProject
    var project: TrimatoProject {
        get { storedProject }
        set {
            objectWillChange.send()
            storedProject = newValue
            setHasUnsavedChanges(newValue != explicitlySavedProject)
        }
    }
    private(set) var hasUnsavedChanges = false
    let unsavedChangesDidChange: CurrentValueSubject<Bool, Never>

    private var explicitlySavedProject: TrimatoProject

    init(project: TrimatoProject = TrimatoProject(), isExplicitlySaved: Bool = true) {
        storedProject = project
        explicitlySavedProject = isExplicitlySaved ? project : TrimatoProject()
        hasUnsavedChanges = !isExplicitlySaved
        unsavedChangesDidChange = CurrentValueSubject(!isExplicitlySaved)
    }

    required init(configuration: ReadConfiguration) throws {
        let decoded = try Self.decodeProject(from: configuration.file)
        storedProject = decoded
        explicitlySavedProject = decoded
        unsavedChangesDidChange = CurrentValueSubject(false)
    }

    static func decodeProject(from wrapper: FileWrapper) throws -> TrimatoProject {
        let data: Data
        if wrapper.isDirectory {
            guard let manifest = wrapper.fileWrappers?["project.json"],
                  manifest.isRegularFile,
                  let manifestData = manifest.regularFileContents else {
                throw CocoaError(.fileReadCorruptFile)
            }
            data = manifestData
        } else if wrapper.isRegularFile, let regularData = wrapper.regularFileContents {
            data = regularData
        } else {
            throw CocoaError(.fileReadCorruptFile)
        }

        if let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = manifest["schemaVersion"] as? Int,
           version > TrimatoProject.currentSchemaVersion {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try JSONDecoder().decode(TrimatoProject.self, from: data)
    }

    func snapshot(contentType: UTType) throws -> TrimatoProject {
        project
    }

    func fileWrapper(snapshot: TrimatoProject, configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try Self.manifestData(for: snapshot)
        return FileWrapper(directoryWithFileWrappers: [
            "project.json": FileWrapper(regularFileWithContents: data)
        ])
    }

    static func manifestData(for project: TrimatoProject) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(project)
    }

    func markCurrentProjectAsExplicitlySaved() {
        explicitlySavedProject = project
        setHasUnsavedChanges(false)
    }

    @discardableResult
    func restoreExplicitlySavedProject() -> TrimatoProject {
        let discardedProject = project
        project = explicitlySavedProject
        setHasUnsavedChanges(false)
        return discardedProject
    }

    func reinstateDiscardedProject(_ discardedProject: TrimatoProject) {
        project = discardedProject
    }

    func updatePlaybackPreparation(
        assetID: UUID,
        playbackMode: ProjectMediaPlaybackMode?,
        proxyCacheKey: UUID?,
        sourceFingerprint: SourceMediaFingerprint?
    ) {
        func update(_ project: inout TrimatoProject) {
            guard let index = project.media.firstIndex(where: { $0.id == assetID }) else { return }
            project.media[index].playbackMode = playbackMode
            project.media[index].proxyCacheKey = proxyCacheKey
            project.media[index].sourceFingerprint = sourceFingerprint
        }

        var liveProject = storedProject
        var savedProject = explicitlySavedProject
        update(&liveProject)
        update(&savedProject)
        explicitlySavedProject = savedProject
        storedProject = liveProject
        setHasUnsavedChanges(liveProject != savedProject)
    }

    private func setHasUnsavedChanges(_ newValue: Bool) {
        guard hasUnsavedChanges != newValue else { return }
        hasUnsavedChanges = newValue
        unsavedChangesDidChange.send(newValue)
    }
}
