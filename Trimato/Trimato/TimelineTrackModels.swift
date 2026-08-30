import Foundation

nonisolated enum TimelineTrackKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case video
    case audio

    var id: String { rawValue }
    var title: String { self == .video ? "Video" : "Audio" }
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
    var isMuted = false

    var sortedClips: [TimelineClip] {
        clips.sorted {
            if $0.timelineStart == $1.timelineStart { return $0.id.uuidString < $1.id.uuidString }
            return $0.timelineStart < $1.timelineStart
        }
    }

    var end: ProjectTime {
        max(clips.map(\.visibleTimelineEnd).max() ?? .zero, .zero)
    }
}

nonisolated enum TimelineElementSelection: Hashable, Sendable {
    case clip(UUID)
    case transition(UUID)
}

// Decode older projects without requiring the newly saved mute setting.
nonisolated extension TimelineTrack {
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, role, clips, isMuted
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decode(TimelineTrackKind.self, forKey: .kind)
        role = try values.decode(TimelineTrackRole.self, forKey: .role)
        clips = try values.decode([TimelineClip].self, forKey: .clips)
        isMuted = try values.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
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
