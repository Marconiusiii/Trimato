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

    static let standardFrameRates: [Double] = [
        24_000.0 / 1_001.0,
        24,
        25,
        30_000.0 / 1_001.0,
        30,
        50,
        60_000.0 / 1_001.0,
        60,
        120,
    ]

    static func stableFrameRate(_ frameRate: Double) -> Double {
        guard frameRate.isFinite, frameRate > 0 else { return 30 }
        if let standard = standardFrameRates.min(by: {
            abs($0 - frameRate) < abs($1 - frameRate)
        }), abs(standard - frameRate) <= 0.05 {
            return standard
        }
        return (frameRate * 1_000).rounded() / 1_000
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
        if !tracks.isEmpty {
            return tracks.contains { track in
                track.kind == .video && !track.clips.isEmpty
            }
        }
        return primaryTimeline.contains { clip in asset(id: clip.assetID)?.hasVideo == true } ||
            cutaways.contains { cutaway in asset(id: cutaway.assetID)?.hasVideo == true }
    }

    var hasTimelineAudio: Bool {
        if !tracks.isEmpty {
            return tracks.contains { track in
                track.kind == .audio && !track.clips.isEmpty
            }
        }
        return primaryTimeline.contains { clip in asset(id: clip.assetID)?.hasAudio == true } ||
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
    var timelineStart: ProjectTime = .zero
    var linkedClipID: UUID? = nil
    var audioSettings: AudioClipSettings = .neutral

    var duration: ProjectTime {
        segments.reduce(.zero) { $0 + $1.duration }
    }

    var timelineEnd: ProjectTime { timelineStart + duration }

    var hiddenBeforeTimeline: ProjectTime {
        min(max(.zero - timelineStart, .zero), duration)
    }

    var visibleTimelineStart: ProjectTime {
        max(timelineStart, .zero)
    }

    var visibleTimelineEnd: ProjectTime {
        max(timelineEnd, .zero)
    }

    var visibleDuration: ProjectTime {
        max(visibleTimelineEnd - visibleTimelineStart, .zero)
    }

    var visibleSegments: [SourceSegment] {
        var amountToSkip = hiddenBeforeTimeline
        var result: [SourceSegment] = []
        for segment in segments {
            guard segment.duration.isPositive else { continue }
            if amountToSkip >= segment.duration {
                amountToSkip = amountToSkip - segment.duration
                continue
            }
            let visibleStart = segment.sourceRange.start + amountToSkip
            result.append(SourceSegment(sourceRange: ProjectTimeRange(
                start: visibleStart,
                duration: segment.duration - amountToSkip
            )))
            amountToSkip = .zero
        }
        return result
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
        customName: String? = nil,
        timelineStart: ProjectTime = .zero,
        linkedClipID: UUID? = nil,
        audioSettings: AudioClipSettings = .neutral
    ) {
        self.id = id
        self.assetID = assetID
        self.name = name
        self.segments = segments
        self.labelOrdinal = labelOrdinal
        self.customName = customName
        self.timelineStart = timelineStart
        self.linkedClipID = linkedClipID
        self.audioSettings = audioSettings
    }

    private enum CodingKeys: String, CodingKey {
        case id, assetID, name, segments, labelOrdinal, customName
        case timelineStart, linkedClipID, audioSettings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        assetID = try container.decode(UUID.self, forKey: .assetID)
        name = try container.decode(String.self, forKey: .name)
        segments = try container.decode([SourceSegment].self, forKey: .segments)
        labelOrdinal = try container.decodeIfPresent(Int.self, forKey: .labelOrdinal)
        customName = try container.decodeIfPresent(String.self, forKey: .customName)
        timelineStart = try container.decodeIfPresent(ProjectTime.self, forKey: .timelineStart) ?? .zero
        linkedClipID = try container.decodeIfPresent(UUID.self, forKey: .linkedClipID)
        audioSettings = try container.decodeIfPresent(AudioClipSettings.self, forKey: .audioSettings) ?? .neutral
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
    static let currentSchemaVersion = 2

    var schemaVersion = currentSchemaVersion
    var id = UUID()
    var name: String
    var format = ProjectFormat()
    var targetDuration: ProjectTime?
    var folders: [ProjectFolder] = []
    var media: [MediaAssetRecord] = []
    var primaryTimeline: [TimelineClip] = []
    var cutaways: [TimelineCutaway] = []
    var tracks: [TimelineTrack] = []
    var transitions: [TimelineTransition] = []

    init(name: String = "Untitled Project") {
        self.name = name
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, format, targetDuration, folders, media
        case primaryTimeline, cutaways, tracks, transitions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Project"
        format = try container.decodeIfPresent(ProjectFormat.self, forKey: .format) ?? ProjectFormat()
        if format.mode == .automatic, let frameRate = format.frameRate {
            format.frameRate = ProjectFormat.stableFrameRate(frameRate)
        }
        targetDuration = try container.decodeIfPresent(ProjectTime.self, forKey: .targetDuration)
        folders = try container.decodeIfPresent([ProjectFolder].self, forKey: .folders) ?? []
        media = try container.decodeIfPresent([MediaAssetRecord].self, forKey: .media) ?? []
        primaryTimeline = try container.decodeIfPresent([TimelineClip].self, forKey: .primaryTimeline) ?? []
        cutaways = try container.decodeIfPresent([TimelineCutaway].self, forKey: .cutaways) ?? []
        tracks = try container.decodeIfPresent([TimelineTrack].self, forKey: .tracks) ?? []
        transitions = try container.decodeIfPresent([TimelineTransition].self, forKey: .transitions) ?? []
        if tracks.isEmpty {
            tracks = Self.migratedTracks(
                primaryTimeline: &primaryTimeline,
                cutaways: cutaways,
                media: media
            )
        }
        schemaVersion = Self.currentSchemaVersion
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(format, forKey: .format)
        try container.encodeIfPresent(targetDuration, forKey: .targetDuration)
        try container.encode(folders, forKey: .folders)
        try container.encode(media, forKey: .media)
        try container.encode(primaryTimeline, forKey: .primaryTimeline)
        try container.encode(cutaways, forKey: .cutaways)
        try container.encode(tracks, forKey: .tracks)
        try container.encode(transitions, forKey: .transitions)
    }

    var duration: ProjectTime {
        if !tracks.isEmpty {
            return tracks.map(\.end).max() ?? .zero
        }
        return primaryTimeline.reduce(.zero) { $0 + $1.duration }
    }

    func track(id: UUID) -> TimelineTrack? {
        tracks.first { $0.id == id }
    }

    func timelineClip(id: UUID) -> TimelineClip? {
        for track in tracks {
            if let clip = track.clips.first(where: { $0.id == id }) { return clip }
        }
        return primaryTimeline.first { $0.id == id }
    }

    func transition(id: UUID) -> TimelineTransition? {
        transitions.first { $0.id == id }
    }

    func asset(id: UUID) -> MediaAssetRecord? {
        media.first { $0.id == id }
    }

    func startTime(of clipID: UUID) -> ProjectTime? {
        if let clip = timelineClip(id: clipID), !tracks.isEmpty { return clip.timelineStart }
        var cursor = ProjectTime.zero
        for clip in primaryTimeline {
            if clip.id == clipID { return cursor }
            cursor = cursor + clip.duration
        }
        return nil
    }

    static func migratedTracks(
        primaryTimeline: inout [TimelineClip],
        cutaways: [TimelineCutaway],
        media: [MediaAssetRecord]
    ) -> [TimelineTrack] {
        func asset(_ id: UUID) -> MediaAssetRecord? { media.first { $0.id == id } }
        var videoClips: [TimelineClip] = []
        var audioClips: [TimelineClip] = []
        var cursor = ProjectTime.zero
        for index in primaryTimeline.indices {
            primaryTimeline[index].timelineStart = cursor
            let source = primaryTimeline[index]
            if asset(source.assetID)?.hasVideo == true {
                var video = source
                video.timelineStart = cursor
                if asset(source.assetID)?.hasAudio == true {
                    var audio = source
                    audio.id = UUID()
                    audio.name = "\(source.displayName) Audio"
                    audio.labelOrdinal = nil
                    audio.customName = nil
                    video.linkedClipID = audio.id
                    audio.linkedClipID = video.id
                    videoClips.append(video)
                    audioClips.append(audio)
                } else {
                    videoClips.append(video)
                }
            } else if asset(source.assetID)?.hasAudio == true {
                var audio = source
                audio.timelineStart = cursor
                audioClips.append(audio)
            }
            cursor = cursor + source.duration
        }

        var result: [TimelineTrack] = []
        if !videoClips.isEmpty {
            result.append(TimelineTrack(name: "Primary Video", kind: .video, role: .primaryVideo, clips: videoClips))
        }
        if !audioClips.isEmpty {
            result.append(TimelineTrack(name: "Primary Audio", kind: .audio, role: .primaryAudio, clips: audioClips))
        }
        if !cutaways.isEmpty {
            let clips = cutaways.map {
                TimelineClip(
                    id: $0.id,
                    assetID: $0.assetID,
                    name: $0.name,
                    segments: $0.segments,
                    labelOrdinal: $0.labelOrdinal,
                    customName: $0.customName,
                    timelineStart: $0.start
                )
            }
            result.append(TimelineTrack(name: "Video 2", kind: .video, clips: clips))
            let audioCutaways = cutaways.filter {
                $0.audioMode == .sourceAudio && asset($0.assetID)?.hasAudio == true
            }.map {
                TimelineClip(
                    assetID: $0.assetID,
                    name: "\($0.displayName) Audio",
                    segments: $0.segments,
                    timelineStart: $0.start
                )
            }
            if !audioCutaways.isEmpty {
                result.append(TimelineTrack(name: "Audio 2", kind: .audio, clips: audioCutaways))
            }
        }
        return result
    }
}
