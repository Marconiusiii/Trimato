import SwiftUI

struct QuickTransitionView: View {
    @Environment(\.dismiss) private var dismiss

    let project: TrimatoProject
    let request: TransitionRequest
    let add: ([TimelineTransition]) throws -> Void
    let finished: () -> Void

    @State private var addIntro = true
    @State private var addOutro = true
    @State private var includeAudio = true
    @State private var durationText = TransitionDurationInput.defaultText
    @State private var validationMessage: String?
    @State private var isSubmitting = false
    @AccessibilityFocusState private var validationMessageFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if request.mode == .quickCross {
                Text(crossDescription)
            } else {
                Text(clip?.displayName ?? "Timeline clip")
                    .foregroundStyle(.secondary)
                Toggle("Intro", isOn: $addIntro)
                Toggle("Outro", isOn: $addOutro)
            }

            if showsAudioToggle {
                Toggle(request.mode == .quickFade ? "Fade Audio" : "Crossfade Audio", isOn: $includeAudio)
            }

            TransitionDurationField(text: $durationText)

            if let validationMessage {
                Text(validationMessage)
                    .foregroundStyle(.red)
                    .accessibilityFocused($validationMessageFocused)
            }

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Button(applyTitle, action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSubmitting || (request.mode == .quickFade && !addIntro && !addOutro))
            }
        }
        .padding(20)
        .frame(width: 430)
        .onDisappear(perform: finished)
    }

    private var track: TimelineTrack? { project.track(id: request.trackID) }
    private var clip: TimelineClip? { project.timelineClip(id: request.clipID) }
    private var orderedClips: [TimelineClip] { track?.sortedClips ?? [] }
    private var clipIndex: Int? { orderedClips.firstIndex { $0.id == request.clipID } }
    private var followingClip: TimelineClip? {
        guard let clipIndex, clipIndex + 1 < orderedClips.count else { return nil }
        return orderedClips[clipIndex + 1]
    }

    private var title: String {
        if request.mode == .quickFade { return "Quick Fade" }
        return track?.kind == .audio ? "Quick Cross Fade" : "Quick Cross Dissolve"
    }

    private var applyTitle: String {
        request.mode == .quickFade ? "Apply Fade" : (track?.kind == .audio ? "Apply Cross Fade" : "Apply Cross Dissolve")
    }

    private var crossDescription: String {
        guard let clip, let followingClip else { return "No following edit" }
        return "\(clip.displayName) to \(followingClip.displayName)"
    }

    private var linkedAudioContext: (track: TimelineTrack, leading: TimelineClip, trailing: TimelineClip?)? {
        guard let clip, let linkedID = clip.linkedClipID,
              let audioTrack = project.tracks.first(where: { $0.kind == .audio && $0.clips.contains { $0.id == linkedID } }),
              let leading = audioTrack.clips.first(where: { $0.id == linkedID }) else { return nil }
        let trailing: TimelineClip?
        if let followingLinkedID = followingClip?.linkedClipID {
            trailing = audioTrack.clips.first(where: { $0.id == followingLinkedID })
        } else {
            trailing = nil
        }
        return (audioTrack, leading, trailing)
    }

    private var showsAudioToggle: Bool {
        guard track?.kind == .video, let context = linkedAudioContext else { return false }
        return request.mode == .quickFade || context.trailing != nil
    }

    private func apply() {
        guard let duration = TransitionDurationInput.parse(durationText) else {
            showValidation("Enter a duration greater than zero, such as 1.0 or 1.25 seconds.")
            return
        }
        guard let track, let clip else {
            showValidation("The timeline clip is no longer available.")
            return
        }
        if request.mode == .quickFade {
            var transitions: [TimelineTransition] = []
            if addIntro { transitions.append(fade(edge: .intro, clip: clip, track: track, duration: duration)) }
            if addOutro { transitions.append(fade(edge: .outro, clip: clip, track: track, duration: duration)) }
            if includeAudio, let context = linkedAudioContext {
                if addIntro { transitions.append(fade(edge: .intro, clip: context.leading, track: context.track, duration: duration)) }
                if addOutro { transitions.append(fade(edge: .outro, clip: context.leading, track: context.track, duration: duration)) }
            }
            submit(transitions)
            return
        }
        guard let followingClip else {
            showValidation("Move the playhead to a clip with a following edit.")
            return
        }
        var transitions = [TimelineTransition(
            trackID: track.id,
            edge: .between,
            kind: track.kind == .video ? .video(.crossDissolve) : .audio(.crossFade),
            duration: duration,
            leadingClipID: clip.id,
            trailingClipID: followingClip.id
        )]
        if includeAudio, let context = linkedAudioContext, let trailing = context.trailing {
            transitions.append(TimelineTransition(
                trackID: context.track.id,
                edge: .between,
                kind: .audio(.crossFade),
                duration: duration,
                leadingClipID: context.leading.id,
                trailingClipID: trailing.id
            ))
        }
        submit(transitions)
    }

    private func submit(_ transitions: [TimelineTransition]) {
        isSubmitting = true
        do {
            try add(transitions)
            dismiss()
        } catch {
            isSubmitting = false
            showValidation("Transition could not be added. \(error.localizedDescription)")
        }
    }

    private func showValidation(_ message: String) {
        validationMessageFocused = false
        validationMessage = message
        DispatchQueue.main.async {
            validationMessageFocused = true
        }
    }

    private func fade(
        edge: TimelineTransitionEdge,
        clip: TimelineClip,
        track: TimelineTrack,
        duration: ProjectTime
    ) -> TimelineTransition {
        TimelineTransition(
            trackID: track.id,
            edge: edge,
            kind: track.kind == .video ? .video(.fade) : .audio(.fade),
            duration: duration,
            leadingClipID: edge == .outro ? clip.id : nil,
            trailingClipID: edge == .intro ? clip.id : nil
        )
    }
}
