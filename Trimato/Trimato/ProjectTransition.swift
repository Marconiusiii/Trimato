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
    var trackID: UUID
    var edge: TimelineTransitionEdge
    var kind: TimelineTransitionKind
    var duration: ProjectTime
    var leadingClipID: UUID?
    var trailingClipID: UUID?

    var displayName: String {
        switch kind {
        case .video(let type):
            if type == .fade { return edge == .intro ? "Fade In" : "Fade Out" }
            return type.title
        case .audio(let type):
            if type == .fade { return edge == .intro ? "Audio Fade In" : "Audio Fade Out" }
            return type.title
        }
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
}
