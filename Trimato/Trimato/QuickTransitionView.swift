import AppKit
import SwiftUI

struct QuickTransitionView: View {
    let project: TrimatoProject
    let request: TransitionRequest
    let add: ([TimelineTransition]) -> Void
    let finished: () -> Void

    @State private var addIntro = true
    @State private var addOutro = true
    @State private var includeAudio = true
    @State private var durationText = TransitionDurationInput.defaultText
    @State private var fadeInDurationText = TransitionDurationInput.defaultText
    @State private var fadeOutDurationText = TransitionDurationInput.defaultText
    @State private var presentedError: TransitionPresentedError?

    var body: some View {
        form
        .alert(presentedError?.title ?? "Transition error", isPresented: errorIsPresented) {
            Button("OK") { presentedError = nil }
        } message: {
            Text(presentedError?.message ?? "Trimato could not apply the transition.")
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 12) {
                if request.mode == .quickCross {
                    Text(crossDescription)
                } else {
                    Toggle(fadeLabel(.intro), isOn: $addIntro)
                    if addIntro { TransitionDurationField(text: $fadeInDurationText, label: FadeTransitionLabels.duration(edge: .intro)) }
                    Toggle(fadeLabel(.outro), isOn: $addOutro)
                    if addOutro { TransitionDurationField(text: $fadeOutDurationText, label: FadeTransitionLabels.duration(edge: .outro)) }
                }

                if showsAudioToggle {
                    Toggle(request.mode == .quickFade ? "Fade Audio" : "Crossfade Audio", isOn: $includeAudio)
                }

                if request.mode == .quickCross { TransitionDurationField(text: $durationText) }
            }

            HStack {
                Button("Cancel", role: .cancel, action: finished)
                Button(applyTitle, action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(request.mode == .quickFade && !addIntro && !addOutro)
            }
        }
        .padding(20)
        .frame(width: 430)
    }

    private var transitionName: String {
        if request.mode == .quickFade { return "Fade" }
        return track?.kind == .audio ? "Cross Fade" : "Cross Dissolve"
    }


    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { presentedError != nil },
            set: { presented in
                if !presented { presentedError = nil }
            }
        )
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
        if request.mode == .quickFade {
            return track?.kind == .video && [TimelineTransitionEdge.intro, .outro].contains { edge in
                guard let linkedID = request.fadeClip(for: edge, in: project)?.linkedClipID else { return false }
                return project.tracks.contains { $0.kind == .audio && $0.clips.contains { $0.id == linkedID } }
            }
        }
        guard track?.kind == .video, let context = linkedAudioContext else { return false }
        return context.trailing != nil
    }

    private func fadeLabel(_ edge: TimelineTransitionEdge) -> String {
        FadeTransitionLabels.control(edge: edge,
            clipName: request.fadeClip(for: edge, in: project)?.displayName ?? "Timeline clip")
    }

    private func apply() {
        guard let duration = TransitionDurationInput.parse(request.mode == .quickCross ? durationText : "1") else {
            showValidation("Enter a duration greater than zero, such as 1.0 or 1.25 seconds.")
            return
        }
        guard let track, let clip else {
            showValidation("The timeline clip is no longer available.")
            return
        }
        if request.mode == .quickFade {
            guard let fadeIn = TransitionDurationInput.parse(addIntro ? fadeInDurationText : "1"),
                  let fadeOut = TransitionDurationInput.parse(addOutro ? fadeOutDurationText : "1") else {
                showValidation("Enter a duration greater than zero for each enabled fade.")
                return
            }
            guard let transitions = request.makeFades(in: project,
                fadeInDuration: addIntro ? fadeIn : nil, fadeOutDuration: addOutro ? fadeOut : nil,
                includeAudio: includeAudio) else {
                showValidation("The timeline clip is no longer available.")
                return
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
        add(transitions)
    }

    private func showValidation(_ message: String) {
        presentedError = .invalidSettings(message)
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
