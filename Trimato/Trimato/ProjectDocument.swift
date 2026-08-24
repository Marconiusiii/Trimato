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
        let data: Data
        if let regularData = configuration.file.regularFileContents {
            data = regularData
        } else if let manifest = configuration.file.fileWrappers?["project.json"]?.regularFileContents {
            data = manifest
        } else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let decoded = try JSONDecoder().decode(TrimatoProject.self, from: data)
        guard decoded.schemaVersion <= TrimatoProject.currentSchemaVersion else {
            throw CocoaError(.fileReadCorruptFile)
        }
        project = decoded
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
