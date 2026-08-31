import SwiftUI

struct AddTransitionView: View {
    let project: TrimatoProject
    let request: TransitionRequest
    let add: ([TimelineTransition]) -> Void
    let cancel: () -> Void

    @State private var addIntro = false
    @State private var addOutro = false
    @State private var introVideoType = VideoTransitionType.fade
    @State private var outroVideoType = VideoTransitionType.fade
    @State private var introAudioType = AudioTransitionType.fade
    @State private var outroAudioType = AudioTransitionType.fade
    @State private var introDuration = TransitionDurationInput.defaultText
    @State private var outroDuration = TransitionDurationInput.defaultText
    @State private var includeIntroAudio = false
    @State private var includeOutroAudio = false
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
            Text("Add Transition")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(clip?.displayName ?? "Timeline clip")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                Toggle(edgeLabel(.intro), isOn: $addIntro)
                if addIntro { transitionControls(edge: .intro) }

                Toggle(edgeLabel(.outro), isOn: $addOutro)
                if addOutro { transitionControls(edge: .outro) }
            }

            HStack {
                Button("Cancel", role: .cancel, action: cancel)
                Button("Add", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!addIntro && !addOutro)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var applicationName: String {
        if addIntro, !addOutro { return introTransitionName }
        if addOutro, !addIntro { return outroTransitionName }
        return "Transitions"
    }


    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { presentedError != nil },
            set: { presented in
                if !presented { presentedError = nil }
            }
        )
    }

    private var introTransitionName: String {
        track?.kind == .video ? introVideoType.title : introAudioType.title
    }

    private var outroTransitionName: String {
        track?.kind == .video ? outroVideoType.title : outroAudioType.title
    }

    private func isFade(_ edge: TimelineTransitionEdge) -> Bool {
        track?.kind == .video ? videoTypeBinding(edge).wrappedValue == .fade
            : audioTypeBinding(edge).wrappedValue == .fade
    }

    private func edgeLabel(_ edge: TimelineTransitionEdge) -> String {
        isFade(edge) ? FadeTransitionLabels.control(edge: edge, clipName: clip?.displayName ?? "Timeline clip")
            : (edge == .intro ? "Intro" : "Outro")
    }

    @ViewBuilder
    private func transitionControls(edge: TimelineTransitionEdge) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !isFade(edge) {
                Text(edge == .intro ? "Intro transition" : "Outro transition")
                    .font(.subheadline)
            }
            if track?.kind == .video {
                labeledVideoPicker(selection: videoTypeBinding(edge), values: videoTypes(for: edge))
                if hasLinkedAudio && !isWipe(videoTypeBinding(edge).wrappedValue) {
                    Toggle(audioToggleLabel(for: videoTypeBinding(edge).wrappedValue), isOn: audioInclusionBinding(edge))
                }
            } else {
                labeledAudioPicker(selection: audioTypeBinding(edge), values: audioTypes(for: edge))
            }
            TransitionDurationField(
                text: durationBinding(edge),
                label: isFade(edge)
                    ? FadeTransitionLabels.duration(edge: edge)
                    : (edge == .intro ? "Intro Duration in Seconds" : "Outro Duration in Seconds")
            )
        }
        .padding(.leading, 12)
    }

    @ViewBuilder
    private func labeledVideoPicker(
        selection: Binding<VideoTransitionType>,
        values: [VideoTransitionType]
    ) -> some View {
        Picker("Transition Type", selection: selection) {
            ForEach(values) { value in
                Text(value.title).tag(value)
            }
        }
    }

    private func labeledAudioPicker(
        selection: Binding<AudioTransitionType>,
        values: [AudioTransitionType]
    ) -> some View {
        Picker("Transition Type", selection: selection) {
            ForEach(values) { value in
                Text(value.title).tag(value)
            }
        }
    }

    private var track: TimelineTrack? { project.track(id: request.trackID) }
    private var clip: TimelineClip? { project.timelineClip(id: request.clipID) }
    private var clipIndex: Int? { track?.sortedClips.firstIndex { $0.id == request.clipID } }

    private var hasLinkedAudio: Bool {
        guard let linked = clip?.linkedClipID else { return false }
        return project.tracks.contains { $0.kind == .audio && $0.clips.contains { $0.id == linked } }
    }

    private func hasNeighbor(_ edge: TimelineTransitionEdge) -> Bool {
        guard let track, let clipIndex else { return false }
        return edge == .intro ? clipIndex > 0 : clipIndex + 1 < track.clips.count
    }

    private func videoTypes(for edge: TimelineTransitionEdge) -> [VideoTransitionType] {
        hasNeighbor(edge) ? VideoTransitionType.allCases : [.fade]
    }

    private func audioTypes(for edge: TimelineTransitionEdge) -> [AudioTransitionType] {
        hasNeighbor(edge) ? AudioTransitionType.allCases : [.fade]
    }

    private func videoTypeBinding(_ edge: TimelineTransitionEdge) -> Binding<VideoTransitionType> {
        edge == .intro ? $introVideoType : $outroVideoType
    }

    private func audioTypeBinding(_ edge: TimelineTransitionEdge) -> Binding<AudioTransitionType> {
        edge == .intro ? $introAudioType : $outroAudioType
    }

    private func durationBinding(_ edge: TimelineTransitionEdge) -> Binding<String> {
        edge == .intro ? $introDuration : $outroDuration
    }

    private func audioInclusionBinding(_ edge: TimelineTransitionEdge) -> Binding<Bool> {
        edge == .intro ? $includeIntroAudio : $includeOutroAudio
    }

    private func apply() {
        let intro = addIntro ? TransitionDurationInput.parse(introDuration) : nil
        let outro = addOutro ? TransitionDurationInput.parse(outroDuration) : nil
        if (addIntro && intro == nil) || (addOutro && outro == nil) {
            showValidation("Enter a duration greater than zero, such as 1.0 or 1.25 seconds.")
            return
        }
        var result: [TimelineTransition] = []
        if let intro { result.append(contentsOf: makeTransitions(edge: .intro, duration: intro)) }
        if let outro { result.append(contentsOf: makeTransitions(edge: .outro, duration: outro)) }
        add(result)
    }

    private func showValidation(_ message: String) {
        presentedError = .invalidSettings(message)
    }

    private func makeTransitions(edge: TimelineTransitionEdge, duration: ProjectTime) -> [TimelineTransition] {
        guard let track, let clip, let clipIndex else { return [] }
        let videoType = videoTypeBinding(edge).wrappedValue
        let audioType = audioTypeBinding(edge).wrappedValue
        let isBetween = track.kind == .video ? videoType != .fade : audioType != .fade
        if !isBetween {
            return request.makeFades(in: project,
                fadeInDuration: edge == .intro ? duration : nil,
                fadeOutDuration: edge == .outro ? duration : nil,
                includeAudio: audioInclusionBinding(edge).wrappedValue) ?? []
        }
        let neighboring = isBetween ? neighborIDs(edge: edge, clips: track.sortedClips, index: clipIndex) : nil
        let transition = TimelineTransition(
            trackID: track.id,
            edge: isBetween ? .between : edge,
            kind: track.kind == .video ? .video(videoType) : .audio(audioType),
            duration: duration,
            leadingClipID: neighboring?.leading ?? (edge == .outro ? clip.id : nil),
            trailingClipID: neighboring?.trailing ?? (edge == .intro ? clip.id : nil)
        )
        var result = [transition]
        if track.kind == .video, !isWipe(videoType), audioInclusionBinding(edge).wrappedValue,
           let linkedID = clip.linkedClipID,
           let audioTrack = project.tracks.first(where: { $0.kind == .audio && $0.clips.contains { $0.id == linkedID } }),
           let audioIndex = audioTrack.sortedClips.firstIndex(where: { $0.id == linkedID }) {
            let audioNeighbor = isBetween ? neighborIDs(edge: edge, clips: audioTrack.sortedClips, index: audioIndex) : nil
            result.append(TimelineTransition(
                trackID: audioTrack.id,
                edge: isBetween ? .between : edge,
                kind: .audio(linkedAudioType(for: videoType, isBetween: isBetween)),
                duration: duration,
                leadingClipID: audioNeighbor?.leading ?? (edge == .outro ? linkedID : nil),
                trailingClipID: audioNeighbor?.trailing ?? (edge == .intro ? linkedID : nil)
            ))
        }
        return result
    }

    private func neighborIDs(edge: TimelineTransitionEdge, clips: [TimelineClip], index: Int) -> (leading: UUID, trailing: UUID)? {
        if edge == .intro, index > 0 { return (clips[index - 1].id, clips[index].id) }
        if edge == .outro, index + 1 < clips.count { return (clips[index].id, clips[index + 1].id) }
        return nil
    }

    private func isWipe(_ type: VideoTransitionType) -> Bool {
        type == .wipeLeft || type == .wipeRight || type == .wipeUp || type == .wipeDown
    }

    private func audioToggleLabel(for type: VideoTransitionType) -> String {
        type == .crossDissolve ? "Crossfade Audio" : "Fade Audio"
    }

    private func linkedAudioType(
        for videoType: VideoTransitionType,
        isBetween: Bool
    ) -> AudioTransitionType {
        guard isBetween else { return .fade }
        return videoType == .fadeOutIn ? .fadeOutIn : .crossFade
    }
}
