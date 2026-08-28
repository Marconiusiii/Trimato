import SwiftUI

struct AddTransitionView: View {
    let project: TrimatoProject
    let request: TransitionRequest
    let progress: Double
    let add: ([TimelineTransition]) async throws -> Void
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
    @State private var isSubmitting = false
    @State private var submissionTask: Task<Void, Never>?
    @AccessibilityFocusState private var focusedPicker: TransitionPickerFocus?
    @AccessibilityFocusState private var progressFocused: Bool

    var body: some View {
        Group {
            if isSubmitting {
                VStack(spacing: 16) {
                    ProgressView(value: boundedProgress, total: 1) {
                        Text("Applying \(applicationName)…")
                    }
                        .accessibilityLabel("Applying \(applicationName)")
                        .accessibilityValue(TransitionProgressAccessibility.value(progress))
                        .accessibilityFocused($progressFocused)
                        .onChange(of: TransitionProgressAccessibility.milestone(progress)) { _, milestone in
                            TransitionProgressAccessibility.announce(milestone, transitionName: applicationName)
                        }
                    Button("Cancel", role: .cancel) {
                        submissionTask?.cancel()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                .padding(32)
                .frame(width: 440)
                .frame(minHeight: 180)
            } else {
                form
            }
        }
        .interactiveDismissDisabled(isSubmitting)
        .onDisappear { submissionTask?.cancel() }
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

            Form {
                Toggle("Intro", isOn: $addIntro)
                if addIntro { transitionControls(edge: .intro) }

                Toggle("Outro", isOn: $addOutro)
                if addOutro { transitionControls(edge: .outro) }
            }
            .formStyle(.grouped)
            .frame(height: transitionFormHeight)

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

    private var transitionFormHeight: CGFloat {
        if addIntro && addOutro { return 380 }
        if addIntro || addOutro { return 250 }
        return 100
    }

    private var boundedProgress: Double { min(max(progress, 0), 1) }

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

    @ViewBuilder
    private func transitionControls(edge: TimelineTransitionEdge) -> some View {
        Section(edge == .intro ? "Intro transition" : "Outro transition") {
                if track?.kind == .video {
                    labeledVideoPicker(edge: edge, selection: videoTypeBinding(edge), values: videoTypes(for: edge))
                    if hasLinkedAudio && !isWipe(videoTypeBinding(edge).wrappedValue) {
                        Toggle(audioToggleLabel(for: videoTypeBinding(edge).wrappedValue), isOn: audioInclusionBinding(edge))
                    }
                } else {
                    labeledAudioPicker(edge: edge, selection: audioTypeBinding(edge), values: audioTypes(for: edge))
                }
                TransitionDurationField(text: durationBinding(edge))
        }
    }

    @ViewBuilder
    private func labeledVideoPicker(
        edge: TimelineTransitionEdge,
        selection: Binding<VideoTransitionType>,
        values: [VideoTransitionType]
    ) -> some View {
        Picker("Transition Type", selection: pickerBinding(selection, edge: edge)) {
            ForEach(values) { value in
                Text(value.title).tag(value)
            }
        }
        .accessibilityFocused($focusedPicker, equals: pickerFocus(for: edge))
    }

    private func labeledAudioPicker(
        edge: TimelineTransitionEdge,
        selection: Binding<AudioTransitionType>,
        values: [AudioTransitionType]
    ) -> some View {
        Picker("Transition Type", selection: pickerBinding(selection, edge: edge)) {
            ForEach(values) { value in
                Text(value.title).tag(value)
            }
        }
        .accessibilityFocused($focusedPicker, equals: pickerFocus(for: edge))
    }

    private func pickerBinding<Value>(_ binding: Binding<Value>, edge: TimelineTransitionEdge) -> Binding<Value> {
        Binding(
            get: { binding.wrappedValue },
            set: { value in
                binding.wrappedValue = value
                restorePickerFocus(for: edge)
            }
        )
    }

    private func pickerFocus(for edge: TimelineTransitionEdge) -> TransitionPickerFocus {
        edge == .intro ? .intro : .outro
    }

    private func restorePickerFocus(for edge: TimelineTransitionEdge) {
        let target = pickerFocus(for: edge)
        focusedPicker = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            focusedPicker = target
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            focusedPicker = target
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
        isSubmitting = true
        submissionTask = Task { @MainActor in
            await Task.yield()
            progressFocused = true
            do {
                try await add(result)
                submissionTask = nil
                cancel()
            } catch is CancellationError {
                submissionTask = nil
                progressFocused = false
                isSubmitting = false
                cancel()
            } catch {
                submissionTask = nil
                progressFocused = false
                isSubmitting = false
                presentedError = .applicationFailed(
                    transitionName: applicationName,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func showValidation(_ message: String) {
        presentedError = .invalidSettings(message)
    }

    private func makeTransitions(edge: TimelineTransitionEdge, duration: ProjectTime) -> [TimelineTransition] {
        guard let track, let clip, let clipIndex else { return [] }
        let videoType = videoTypeBinding(edge).wrappedValue
        let audioType = audioTypeBinding(edge).wrappedValue
        let isBetween = track.kind == .video ? videoType != .fade : audioType != .fade
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

private enum TransitionPickerFocus: Hashable {
    case intro
    case outro
}
