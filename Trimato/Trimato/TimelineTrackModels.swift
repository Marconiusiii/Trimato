import Foundation

nonisolated enum TimelineTrackKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case video
    case audio
    case captions

    var id: String { rawValue }
    var title: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        case .captions: "Captions"
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
    var isMuted = false
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
}

// Decode older projects without requiring the newly saved mute setting.
nonisolated extension TimelineTrack {
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, role, clips, captionCues, isMuted, recordingPurpose
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decode(TimelineTrackKind.self, forKey: .kind)
        role = try values.decode(TimelineTrackRole.self, forKey: .role)
        clips = try values.decode([TimelineClip].self, forKey: .clips)
        captionCues = try values.decodeIfPresent([CaptionCue].self, forKey: .captionCues) ?? []
        isMuted = try values.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        recordingPurpose = try values.decodeIfPresent(RecordingPurpose.self, forKey: .recordingPurpose)
    }
}

nonisolated enum TimelineMoveDestination: CaseIterable {
    case start, before, after, end

    var title: String {
        switch self {
        case .start: "Start"
        case .before: "Before"
        case .after: "After"
        case .end: "End"
        }
    }
}
