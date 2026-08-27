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

nonisolated enum ProjectMediaPlaybackMode: String, Codable, Hashable, Sendable {
    case nativePassthrough
    case nativeMP4Export
    case cachedProxy
}

nonisolated struct SourceMediaFingerprint: Codable, Hashable, Sendable {
    static let proxyFormatVersion = 2

    var fileSize: Int64
    var modificationTime: TimeInterval
    var proxyFormatVersion: Int
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
    var playbackMode: ProjectMediaPlaybackMode? = nil
    var proxyCacheKey: UUID? = nil
    var sourceFingerprint: SourceMediaFingerprint? = nil

    var editedDuration: ProjectTime {
        sourceEdit.reduce(.zero) { $0 + $1.duration }
    }

    var hasVideo: Bool {
        guard let naturalWidth, let naturalHeight else { return false }
        return naturalWidth > 0 && naturalHeight > 0
    }
}

extension TrimatoProject {
    var hasTimelineVideo: Bool {
        primaryTimeline.contains { clip in asset(id: clip.assetID)?.hasVideo == true } ||
            cutaways.contains { cutaway in asset(id: cutaway.assetID)?.hasVideo == true }
    }

    var hasTimelineAudio: Bool {
        primaryTimeline.contains { clip in asset(id: clip.assetID)?.hasAudio == true } ||
            cutaways.contains { cutaway in
                cutaway.audioMode == .sourceAudio && asset(id: cutaway.assetID)?.hasAudio == true
            }
    }
}

nonisolated struct TimelineClip: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var assetID: UUID
    var name: String
    var segments: [SourceSegment]
    var labelOrdinal: Int?
    var customName: String?

    var duration: ProjectTime {
        segments.reduce(.zero) { $0 + $1.duration }
    }

    var displayName: String {
        if let customName { return customName }
        guard let labelOrdinal else { return name }
        return "\(name) \(Self.letterLabel(for: labelOrdinal))"
    }

    init(
        id: UUID = UUID(),
        assetID: UUID,
        name: String,
        segments: [SourceSegment],
        labelOrdinal: Int? = nil,
        customName: String? = nil
    ) {
        self.id = id
        self.assetID = assetID
        self.name = name
        self.segments = segments
        self.labelOrdinal = labelOrdinal
        self.customName = customName
    }

    static func letterLabel(for ordinal: Int) -> String {
        var value = max(ordinal, 0) + 1
        var characters: [Character] = []
        while value > 0 {
            value -= 1
            characters.append(Character(UnicodeScalar(65 + value % 26)!))
            value /= 26
        }
        return String(characters.reversed())
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
    var labelOrdinal: Int? = nil
    var customName: String? = nil

    var duration: ProjectTime {
        segments.reduce(.zero) { $0 + $1.duration }
    }

    var end: ProjectTime { start + duration }

    var displayName: String {
        if let customName { return customName }
        guard let labelOrdinal else { return name }
        return "\(name) \(TimelineClip.letterLabel(for: labelOrdinal))"
    }
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
