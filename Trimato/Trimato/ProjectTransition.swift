import Foundation

nonisolated enum VideoTransitionType: String, Codable, CaseIterable, Identifiable, Sendable {
    case fade
    case fadeOutIn
    case crossDissolve
    case wipeLeft
    case wipeRight
    case wipeUp
    case wipeDown
    case slideLeft
    case slideRight
    case slideUp
    case slideDown
    case coverLeft
    case coverRight
    case coverUp
    case coverDown
    case revealLeft
    case revealRight
    case revealUp
    case revealDown
    case circleOpen
    case circleClose
    case pixelDissolve
    case fadeThroughWhite

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
        case .slideLeft: "Slide Left"
        case .slideRight: "Slide Right"
        case .slideUp: "Slide Up"
        case .slideDown: "Slide Down"
        case .coverLeft: "Cover Left"
        case .coverRight: "Cover Right"
        case .coverUp: "Cover Up"
        case .coverDown: "Cover Down"
        case .revealLeft: "Reveal Left"
        case .revealRight: "Reveal Right"
        case .revealUp: "Reveal Up"
        case .revealDown: "Reveal Down"
        case .circleOpen: "Circle Open"
        case .circleClose: "Circle Close"
        case .pixelDissolve: "Pixel Dissolve"
        case .fadeThroughWhite: "Fade Through White"

        }
    }
}

nonisolated enum VideoTransitionFamily: String, CaseIterable, Identifiable {
    case fade = "Fade", wipes = "Wipes", slide = "Slide", cover = "Cover"
    case reveal = "Reveal", circle = "Circle", pixelDissolve = "Pixel Dissolve"
    var id: String { rawValue }
    var types: [VideoTransitionType] {
        switch self {
        case .fade: [.crossDissolve, .fadeOutIn, .fadeThroughWhite]
        case .wipes: [.wipeLeft, .wipeRight, .wipeUp, .wipeDown]
        case .slide: [.slideLeft, .slideRight, .slideUp, .slideDown]
        case .cover: [.coverLeft, .coverRight, .coverUp, .coverDown]
        case .reveal: [.revealLeft, .revealRight, .revealUp, .revealDown]
        case .circle: [.circleOpen, .circleClose]
        case .pixelDissolve: [.pixelDissolve]
        }
    }
}

extension VideoTransitionType {
    var family: VideoTransitionFamily {
        VideoTransitionFamily.allCases.first { $0.types.contains(self) } ?? .fade
    }
    var supportsEasing: Bool { family != .fade && family != .pixelDissolve }

    var optionTitle: String {
        switch self {
        case .wipeLeft, .slideLeft, .coverLeft, .revealLeft: "Left"
        case .wipeRight, .slideRight, .coverRight, .revealRight: "Right"
        case .wipeUp, .slideUp, .coverUp, .revealUp: "Up"
        case .wipeDown, .slideDown, .coverDown, .revealDown: "Down"
        case .circleOpen: "Open"
        case .circleClose: "Close"
        case .fadeOutIn: "Black"
        case .fadeThroughWhite: "White"
        default: title
        }
    }
}

nonisolated enum VideoTransitionEase: String, Codable, CaseIterable, Identifiable, Sendable {
    case linear, easeIn, easeOut, easyEase

    var id: String { rawValue }
    var title: String {
        switch self {
        case .linear: "Linear"
        case .easeIn: "Ease In"
        case .easeOut: "Ease Out"
        case .easyEase: "Easy Ease"
        }
    }

    // FFmpeg's P runs from 1 (outgoing) to 0 (incoming).
    // Trimato names easing for the arrival/departure of the picture:
    // Ease In slows into the incoming clip; Ease Out accelerates away.
    var remainingProgressExpression: String {
        switch self {
        case .linear: "P"
        case .easeIn: "(P*P)"
        case .easeOut: "(1-(1-P)*(1-P))"
        case .easyEase: "(P*P*(3-2*P))"
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
    var audioCurve: AudioCrossFadeCurve? = nil
    var videoEase: VideoTransitionEase? = nil

    var effectiveAudioCurve: AudioCrossFadeCurve { audioCurve ?? .linear }

    var effectiveVideoEase: VideoTransitionEase {
        guard edge == .between, case .video(let type) = kind, type.supportsEasing else { return .linear }
        return videoEase ?? .linear
    }

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

nonisolated struct TransitionEdit: Hashable, Sendable {
    let leadingClipID: UUID
    let trailingClipID: UUID

    func description(in project: TrimatoProject) -> String {
        let leading = project.timelineClip(id: leadingClipID)?.displayName ?? "Outgoing clip"
        let trailing = project.timelineClip(id: trailingClipID)?.displayName ?? "Incoming clip"
        return "\(leading) to \(trailing)"
    }

    func linkedAudioEdit(in project: TrimatoProject) -> (trackID: UUID, edit: TransitionEdit)? {
        guard let leading = project.timelineClip(id: leadingClipID),
              let trailing = project.timelineClip(id: trailingClipID),
              let leadingAudioID = leading.linkedClipID, let trailingAudioID = trailing.linkedClipID,
              let track = project.tracks.first(where: { track in
                  track.kind == .audio && track.clips.contains { $0.id == leadingAudioID }
                      && track.clips.contains { $0.id == trailingAudioID }
              }),
              let leadingAudio = track.clips.first(where: { $0.id == leadingAudioID }),
              let trailingAudio = track.clips.first(where: { $0.id == trailingAudioID }),
              leadingAudio.timelineEnd == leading.timelineEnd,
              trailingAudio.timelineStart == trailing.timelineStart else { return nil }
        return (track.id, TransitionEdit(leadingClipID: leadingAudioID, trailingClipID: trailingAudioID))
    }

    func makeTransitions(trackID: UUID, kind: TimelineTransitionKind, duration: ProjectTime,
                         includeAudio: Bool, audioType: AudioTransitionType? = nil,
                         audioCurve: AudioCrossFadeCurve = .linear, videoEase: VideoTransitionEase = .linear, in project: TrimatoProject) -> [TimelineTransition] {
        var result = [TimelineTransition(trackID: trackID, edge: .between, kind: kind,
            duration: duration, leadingClipID: leadingClipID, trailingClipID: trailingClipID,
            audioCurve: { if case .audio = kind { return audioCurve }; return nil }(),
            videoEase: { if case .video(let type) = kind, type.supportsEasing { return videoEase }; return nil }())]
        if includeAudio, case .video(let type) = kind,
           let audio = linkedAudioEdit(in: project) {
            result.append(TimelineTransition(trackID: audio.trackID, edge: .between,
                kind: .audio(audioType ?? (type == .fadeOutIn || type == .fadeThroughWhite ? .fadeOutIn : .crossFade)), duration: duration,
                leadingClipID: audio.edit.leadingClipID, trailingClipID: audio.edit.trailingClipID, audioCurve: audioCurve))
        }
        return result
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
    var edit: TransitionEdit? = nil
    // Quick Fade at a shared edit has two targets. Requests made for a
    // selected clip keep both fades on that clip by leaving this unset.
    var fadeOutClipID: UUID? = nil

    func availableEdits(in project: TrimatoProject) -> [TransitionEdit] {
        guard let track = project.track(id: trackID) else { return [] }
        let clips = track.sortedClips
        let candidates = zip(clips, clips.dropFirst()).compactMap { leading, trailing -> TransitionEdit? in
            guard leading.timelineEnd == trailing.timelineStart,
                  leading.id == clipID || trailing.id == clipID else { return nil }
            return TransitionEdit(leadingClipID: leading.id, trailingClipID: trailing.id)
        }
        if let edit { return candidates.filter { $0 == edit } }
        return candidates
    }

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
        edge == .intro ? "Fade In Duration in seconds" : "Fade Out Duration in seconds"
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
