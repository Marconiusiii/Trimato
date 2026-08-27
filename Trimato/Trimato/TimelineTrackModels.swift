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

    var sortedClips: [TimelineClip] {
        clips.sorted {
            if $0.timelineStart == $1.timelineStart { return $0.id.uuidString < $1.id.uuidString }
            return $0.timelineStart < $1.timelineStart
        }
    }

    var end: ProjectTime {
        clips.map(\.timelineEnd).max() ?? .zero
    }
}

nonisolated enum TimelineElementSelection: Hashable, Sendable {
    case clip(UUID)
    case transition(UUID)
}
