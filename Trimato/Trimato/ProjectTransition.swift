import Foundation

nonisolated enum VideoTransitionType: String, Codable, CaseIterable, Identifiable, Sendable {
    case fade
    case fadeOutIn
    case crossDissolve
    case wipeLeft
    case wipeRight
    case wipeUp
    case wipeDown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fade: "Fade"
        case .fadeOutIn: "Fade Out/Fade In"
        case .crossDissolve: "Cross Dissolve"
        case .wipeLeft: "Wipe Left"
        case .wipeRight: "Wipe Right"
        case .wipeUp: "Wipe Up"
        case .wipeDown: "Wipe Down"
        }
    }
}

nonisolated enum AudioTransitionType: String, Codable, CaseIterable, Identifiable, Sendable {
    case fade
    case fadeOutIn
    case crossFade

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fade: "Fade"
        case .fadeOutIn: "Fade Out/Fade In"
        case .crossFade: "Cross Fade"
        }
    }
}

nonisolated enum TimelineTransitionKind: Codable, Equatable, Hashable, Sendable {
    case video(VideoTransitionType)
    case audio(AudioTransitionType)
}

nonisolated enum TimelineTransitionEdge: String, Codable, Sendable {
    case intro
    case outro
    case between
}

nonisolated struct TimelineTransition: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var bundleID: UUID?
    var trackID: UUID
    var edge: TimelineTransitionEdge
    var kind: TimelineTransitionKind
    var duration: ProjectTime
    var leadingClipID: UUID?
    var trailingClipID: UUID?
    var customName: String?

    var displayName: String {
        if let customName = normalizedCustomName {
            return customName
        }
        return defaultDisplayName
    }

    var defaultDisplayName: String {
        switch kind {
        case .video(let type):
            if type == .fade { return edge == .intro ? "Fade In" : "Fade Out" }
            return type.title
        case .audio(let type):
            if type == .fade { return edge == .intro ? "Audio Fade In" : "Audio Fade Out" }
            return type.title
        }
    }

    var normalizedCustomName: String? {
        guard let customName else { return nil }
        let trimmed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated struct TransitionRequest: Identifiable, Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case standard
        case quickCross
        case quickFade
    }

    let id = UUID()
    var trackID: UUID
    var clipID: UUID
    var mode: Mode
    // Quick Fade at a shared edit has two targets. Requests made for a
    // selected clip keep both fades on that clip by leaving this unset.
    var fadeOutClipID: UUID? = nil

    func fadeClip(for edge: TimelineTransitionEdge, in project: TrimatoProject) -> TimelineClip? {
        let id = edge == .outro ? (fadeOutClipID ?? clipID) : clipID
        return project.track(id: trackID)?.clips.first { $0.id == id }
    }

    func makeFades(in project: TrimatoProject, fadeInDuration: ProjectTime?,
                   fadeOutDuration: ProjectTime?, includeAudio: Bool) -> [TimelineTransition]? {
        guard let track = project.track(id: trackID) else { return nil }
        var result: [TimelineTransition] = []
        for (edge, duration) in [(TimelineTransitionEdge.intro, fadeInDuration), (.outro, fadeOutDuration)] {
            guard let duration else { continue }
            guard let clip = fadeClip(for: edge, in: project) else { return nil }
            result.append(Self.fade(edge: edge, clipID: clip.id, track: track, duration: duration))
            if includeAudio, track.kind == .video, let linkedID = clip.linkedClipID,
               let audioTrack = project.tracks.first(where: {
                   $0.kind == .audio && $0.clips.contains { $0.id == linkedID }
               }) {
                result.append(Self.fade(edge: edge, clipID: linkedID, track: audioTrack, duration: duration))
            }
        }
        return result
    }

    private static func fade(edge: TimelineTransitionEdge, clipID: UUID, track: TimelineTrack,
                             duration: ProjectTime) -> TimelineTransition {
        TimelineTransition(trackID: track.id, edge: edge,
            kind: track.kind == .video ? .video(.fade) : .audio(.fade), duration: duration,
            leadingClipID: edge == .outro ? clipID : nil,
            trailingClipID: edge == .intro ? clipID : nil)
    }
}

nonisolated enum FadeTransitionLabels {
    static func control(edge: TimelineTransitionEdge, clipName: String) -> String {
        "\(edge == .intro ? "Fade In" : "Fade Out") \(clipName)"
    }

    static func duration(edge: TimelineTransitionEdge) -> String {
        edge == .intro ? "Fade In Duration" : "Fade Out Duration"
    }
}

nonisolated struct TransitionPresentedError: Identifiable, Equatable, Sendable {
    let id = UUID()
    let title: String
    let message: String

    static func invalidSettings(_ message: String) -> TransitionPresentedError {
        TransitionPresentedError(title: "Check transition settings", message: message)
    }

    static func applicationFailed(
        transitionName: String,
        message: String
    ) -> TransitionPresentedError {
        TransitionPresentedError(
            title: "\(transitionName) could not be applied",
            message: message
        )
    }
}
