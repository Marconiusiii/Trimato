import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let trimatoProject = UTType(
        exportedAs: "com.marconius.trimato.project",
        conformingTo: .package
    )
}

nonisolated enum ProjectFormatMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case custom

    var id: String { rawValue }
}

nonisolated struct ProjectFormat: Codable, Equatable, Sendable {
    var mode: ProjectFormatMode = .automatic
    var width: Int?
    var height: Int?
    var frameRate: Double?

    var isResolved: Bool {
        guard let width, let height, let frameRate else { return false }
        return width > 0 && height > 0 && frameRate > 0
    }
}

nonisolated struct SourceSegment: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var sourceRange: ProjectTimeRange

    var duration: ProjectTime { sourceRange.duration }
}

nonisolated struct ProjectFolder: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var assetIDs: [UUID] = []
}

nonisolated struct MediaAssetRecord: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var originalPath: String
    var bookmarkData: Data?
    var duration: ProjectTime
    var naturalWidth: Int?
    var naturalHeight: Int?
    var frameRate: Double?
    var hasAudio: Bool
    var sourceEdit: [SourceSegment]

    var editedDuration: ProjectTime {
        sourceEdit.reduce(.zero) { $0 + $1.duration }
    }
}

nonisolated struct TimelineClip: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var assetID: UUID
    var name: String
    var segments: [SourceSegment]

    var duration: ProjectTime {
        segments.reduce(.zero) { $0 + $1.duration }
    }
}

nonisolated enum CutawayAudioMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case sourceAudio
    case primaryAudio

    var id: String { rawValue }
}

nonisolated struct TimelineCutaway: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var assetID: UUID
    var name: String
    var start: ProjectTime
    var segments: [SourceSegment]
    var audioMode: CutawayAudioMode

    var duration: ProjectTime {
        segments.reduce(.zero) { $0 + $1.duration }
    }

    var end: ProjectTime { start + duration }
}

nonisolated struct TrimatoProject: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var id = UUID()
    var name: String
    var format = ProjectFormat()
    var targetDuration: ProjectTime?
    var folders: [ProjectFolder] = []
    var media: [MediaAssetRecord] = []
    var primaryTimeline: [TimelineClip] = []
    var cutaways: [TimelineCutaway] = []

    init(name: String = "Untitled Project") {
        self.name = name
    }

    var duration: ProjectTime {
        primaryTimeline.reduce(.zero) { $0 + $1.duration }
    }

    func asset(id: UUID) -> MediaAssetRecord? {
        media.first { $0.id == id }
    }

    func startTime(of clipID: UUID) -> ProjectTime? {
        var cursor = ProjectTime.zero
        for clip in primaryTimeline {
            if clip.id == clipID { return cursor }
            cursor = cursor + clip.duration
        }
        return nil
    }
}
