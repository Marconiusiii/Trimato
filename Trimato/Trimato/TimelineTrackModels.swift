import Foundation

nonisolated enum TimelineTrackKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case video
    case audio
    case captions
    case markers

    var id: String { rawValue }
    var title: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        case .captions: "Captions"
        case .markers: "Markers"
        }
    }
}

nonisolated enum TimelineTrackRole: String, Codable, Sendable {
    case primaryVideo
    case primaryAudio
    case additional
}

nonisolated struct TimelineTrack: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var kind: TimelineTrackKind
    var role: TimelineTrackRole = .additional
    var clips: [TimelineClip] = []
    var captionCues: [CaptionCue] = []
    var markers: [TimelineMarker] = []
    var nextMarkerIndex = 1
    var sortedMarkers: [TimelineMarker] { markers.sorted { $0.time == $1.time ? $0.index < $1.index : $0.time < $1.time } }
    var mix: TrackMixSettings = .neutral
    var isMuted = false
    var magnetic = false

    var isMagnetic: Bool { kind != .captions && kind != .markers && (role != .additional || magnetic) }
    var recordingPurpose: RecordingPurpose? = nil

    var sortedClips: [TimelineClip] {
        clips.sorted {
            if $0.timelineStart == $1.timelineStart { return $0.id.uuidString < $1.id.uuidString }
            return $0.timelineStart < $1.timelineStart
        }
    }

    var sortedCaptionCues: [CaptionCue] {
        captionCues.sorted {
            if $0.start == $1.start { return $0.end < $1.end }
            return $0.start < $1.start
        }
    }

    var end: ProjectTime {
        max(clips.map(\.visibleTimelineEnd).max() ?? .zero,
            captionCues.map(\.end).max() ?? .zero)
    }
}

nonisolated enum TimelineElementSelection: Hashable, Sendable {
    case clip(UUID)
    case transition(UUID)
    case caption(UUID)
    case marker(UUID)
}

// Decode older projects without requiring the newly saved mute setting.
nonisolated extension TimelineTrack {
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, role, clips, captionCues, isMuted, recordingPurpose, mix, magnetic, markers, nextMarkerIndex
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decode(TimelineTrackKind.self, forKey: .kind)
        role = try values.decode(TimelineTrackRole.self, forKey: .role)
        clips = try values.decode([TimelineClip].self, forKey: .clips)
        captionCues = try values.decodeIfPresent([CaptionCue].self, forKey: .captionCues) ?? []
        markers = try values.decodeIfPresent([TimelineMarker].self, forKey: .markers) ?? []
        nextMarkerIndex = try values.decodeIfPresent(Int.self, forKey: .nextMarkerIndex) ?? ((markers.map(\.index).max() ?? 0) + 1)
        mix = (try values.decodeIfPresent(TrackMixSettings.self, forKey: .mix) ?? .neutral).normalized
        isMuted = try values.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        magnetic = try values.decodeIfPresent(Bool.self, forKey: .magnetic) ?? false
        recordingPurpose = try values.decodeIfPresent(RecordingPurpose.self, forKey: .recordingPurpose)
    }
}

nonisolated enum TimelineMoveDestination: CaseIterable {
    case start, before, after, end, playhead

    var title: String {
        switch self {
        case .start: "Start"
        case .before: "Before"
        case .after: "After"
        case .end: "End"
        case .playhead: "Playhead"
        }
    }
}

nonisolated enum TimelineMarkerType: String, Codable, CaseIterable, Sendable {
    case marker = "Marker"
    case chapter = "Chapter"
}

nonisolated struct TimelineMarker: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var index: Int
    var time: ProjectTime
    var title: String
    var type: TimelineMarkerType = .marker
}

extension TrimatoProject {
    var markerTrack: TimelineTrack? { tracks.first { $0.kind == .markers } }
    var visibleCaptionCues: [CaptionCue] { captionTrack?.isMuted == true ? [] : captionTrack?.captionCues ?? [] }
    mutating func insertMarker(at time: ProjectTime) -> TimelineMarker {
        if markerTrack == nil { tracks.append(TimelineTrack(name: "Markers", kind: .markers)) }
        let track = tracks.firstIndex { $0.kind == .markers }!
        let index = tracks[track].nextMarkerIndex
        let marker = TimelineMarker(index: index, time: time, title: "Marker \(index)")
        tracks[track].nextMarkerIndex += 1
        tracks[track].markers.append(marker)
        return marker
    }
}

extension TrimatoProject {
    var withoutMarkers: TrimatoProject {
        var copy = self
        copy.tracks.removeAll { $0.kind == .markers }
        return copy
    }
}
