import Foundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

final class ProjectDocument: ReferenceFileDocument {
    typealias Snapshot = TrimatoProject

    static var readableContentTypes: [UTType] { [.trimatoProject] }
    static var writableContentTypes: [UTType] { [.trimatoProject] }

    @Published var project: TrimatoProject

    init(project: TrimatoProject = TrimatoProject()) {
        self.project = project
    }

    required init(configuration: ReadConfiguration) throws {
        project = try Self.decodeProject(from: configuration.file)
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

        let decoded = try JSONDecoder().decode(TrimatoProject.self, from: data)
        guard decoded.schemaVersion <= TrimatoProject.currentSchemaVersion else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return decoded
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
}
