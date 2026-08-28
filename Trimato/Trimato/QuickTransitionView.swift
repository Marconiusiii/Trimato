import AppKit
import SwiftUI

struct QuickTransitionView: View {
    let project: TrimatoProject
    let request: TransitionRequest
    let progress: Double
    let add: ([TimelineTransition]) async throws -> Void
    let finished: () -> Void

    @State private var addIntro = true
    @State private var addOutro = true
    @State private var includeAudio = true
    @State private var durationText = TransitionDurationInput.defaultText
    @State private var validationMessage: String?
    @State private var isSubmitting = false
    @AccessibilityFocusState private var validationMessageFocused: Bool
    @AccessibilityFocusState private var progressFocused: Bool

    var body: some View {
        Group {
            if isSubmitting {
                VStack(spacing: 16) {
                    ProgressView(value: boundedProgress, total: 1) {
                        Text("Applying \(transitionName)…")
                    }
                        .accessibilityLabel("Applying \(transitionName)")
                        .accessibilityValue(TransitionProgressAccessibility.value(progress))
                        .accessibilityFocused($progressFocused)
                        .onChange(of: TransitionProgressAccessibility.milestone(progress)) { _, milestone in
                            TransitionProgressAccessibility.announce(milestone, transitionName: transitionName)
                        }
                }
                .padding(32)
                .frame(width: 430)
                .frame(minHeight: 180)
            } else {
                form
            }
        }
        .interactiveDismissDisabled(isSubmitting)
    }

    private var form: some View {
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
                Button("Cancel", role: .cancel, action: finished)
                Button(applyTitle, action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSubmitting || (request.mode == .quickFade && !addIntro && !addOutro))
            }
        }
        .padding(20)
        .frame(width: 430)
    }

    private var transitionName: String {
        if request.mode == .quickFade { return "Fade" }
        return track?.kind == .audio ? "Cross Fade" : "Cross Dissolve"
    }

    private var boundedProgress: Double { min(max(progress, 0), 1) }

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
        Task { @MainActor in
            await Task.yield()
            progressFocused = true
            do {
                try await add(transitions)
                finished()
            } catch {
                progressFocused = false
                isSubmitting = false
                showValidation("Transition could not be added. \(error.localizedDescription)")
            }
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

enum TransitionProgressAccessibility {
    nonisolated static func milestone(_ progress: Double) -> Int {
        let bounded = min(max(progress, 0), 1)
        return min(Int(bounded * 10) * 10, 100)
    }

    nonisolated static func value(_ progress: Double) -> String {
        "\(milestone(progress)) percent"
    }

    nonisolated static func announcement(_ milestone: Int, transitionName: String) -> String {
        "Applying \(transitionName), \(milestone) percent"
    }

    @MainActor
    static func announce(_ milestone: Int, transitionName: String) {
        guard milestone > 0, let application = NSApp else { return }
        NSAccessibility.post(
            element: application,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement(milestone, transitionName: transitionName),
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}
