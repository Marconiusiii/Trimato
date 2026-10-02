import SwiftUI
import AppKit
import Combine

@MainActor
final class TransitionToolSession: ObservableObject, Identifiable {
    let id = UUID()
    weak var controller: ProjectController?
    let project: TrimatoProject
    let request: TransitionRequest
    let returnsToEditor: Bool
    let editing: TimelineTransition?
    var returnTarget: TimelineElementSelection
    private let deleteAction: (() -> Void)?
    @Published var hasPendingEdits = false
    @Published private(set) var isApplying = false
    @Published private(set) var completionRequested = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var outcome = OperationProgressOutcome.completed
    private var succeeded = false
    private var operation: Task<Void, Never>?

    init(controller: ProjectController, request: TransitionRequest, returnsToEditor: Bool,
         editing: TimelineTransition? = nil, delete: (() -> Void)? = nil) {
        self.controller = controller
        project = controller.project
        self.request = request
        self.returnsToEditor = returnsToEditor
        self.editing = editing
        deleteAction = delete
        returnTarget = editing.map { .transition($0.id) } ?? .clip(request.clipID)
    }

    func validateProject() throws -> ProjectController {
        guard let controller else { throw QuitDraftError(message: "The transition project is no longer open.") }
        guard controller.project == project else {
            throw QuitDraftError(message: "The project changed. Close this tool and reopen it for the intended clip or transition.")
        }
        return controller
    }

    func apply(_ transitions: [TimelineTransition]) {
        guard !isApplying, !completionRequested else { return }
        errorMessage = nil
        outcome = .completed
        succeeded = false
        isApplying = true
        operation = Task { @MainActor in
            do {
                try Task.checkCancellation()
                let controller = try validateProject()
                guard !transitions.isEmpty else { throw QuitDraftError(message: "Choose at least one transition to apply.") }
                try await controller.applyTransitions(transitions, selectAddedTransition: !returnsToEditor)
                if !returnsToEditor, case .transition(let id) = controller.selection { returnTarget = .transition(id) }
                succeeded = true
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = .failed
                errorMessage = error.localizedDescription
            }
            operation = nil
            completionRequested = true
            isApplying = false
        }
    }

    func cancelApplication() { operation?.cancel() }

    func preparationDismissed() {
        guard !isApplying, completionRequested else { return }
        completionRequested = false
        guard controller?.transitionToolSession === self else { return }
        if succeeded { controller?.dismissTransitionTool() }
        else { controller?.requestToolFocus() }
    }

    func saveForQuit(_ transitions: [TimelineTransition]) throws {
        cancelApplication()
        let controller = try validateProject()
        try controller.addTransitions(transitions, selectAddedTransition: !returnsToEditor)
        controller.dismissTransitionTool(restoreFocus: false)
    }

    func update(_ transition: TimelineTransition) {
        do {
            let controller = try validateProject()
            try controller.updateTransition(transition)
            controller.dismissTransitionTool()
        } catch { errorMessage = error.localizedDescription }
    }

    func updateForQuit(_ transition: TimelineTransition) throws {
        let controller = try validateProject()
        try controller.updateTransition(transition)
        controller.dismissTransitionTool(restoreFocus: false)
    }

    func delete() {
        do {
            _ = try validateProject()
            controller?.dismissTransitionTool(restoreFocus: false)
            deleteAction?()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct TransitionToolView: View {
    @ObservedObject var controller: ProjectController
    @ObservedObject var session: TransitionToolSession
    let focusRevision: Int
    let returnWindow: NSWindow?

    var body: some View {
        Group {
            if let transition = session.editing {
                TransitionEditorView(transition: transition,
                    contextDescription: TimelineElementSequence.contextDescription(for: transition, in: session.project),
                    session: session, focusRevision: focusRevision, cancel: controller.requestCloseToolPane)
            } else if session.request.mode == .standard {
                AddTransitionView(session: session, focusRevision: focusRevision, cancel: controller.requestCloseToolPane)
            } else {
                QuickTransitionView(session: session, focusRevision: focusRevision, finished: controller.requestCloseToolPane)
            }
        }
        .disabled(session.isApplying || session.completionRequested)
        .operationProgress(controller.applyingTransitionName.map {
            OperationProgress(title: "Applying \($0)", progress: controller.applyingTransitionProgress,
                              cancel: session.cancelApplication)
        }, outcome: session.outcome, completionPending: session.isApplying,
           completionRequested: session.completionRequested, returnWindow: returnWindow,
           waitsForReturnWindow: true, dismissed: session.preparationDismissed)
    }
}

struct AddTransitionView: View {
    private struct QuitDraft: Equatable {
        let intro: Bool
        let outro: Bool
        let introVideo: VideoTransitionType
        let outroVideo: VideoTransitionType
        let introAudio: AudioTransitionType
        let outroAudio: AudioTransitionType
        let introDuration: String
        let outroDuration: String
        let includeIntroAudio: Bool
        let includeOutroAudio: Bool
    }
    @ObservedObject var session: TransitionToolSession
    let focusRevision: Int
    let cancel: () -> Void
    private var project: TrimatoProject { session.project }
    private var request: TransitionRequest { session.request }
    @Environment(\.controlActiveState) private var windowActivity
    @State private var appliedFocusRevision: Int?
    @FocusState private var introFocused: Bool

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

    init(session: TransitionToolSession, focusRevision: Int, cancel: @escaping () -> Void) {
        self.session = session
        self.focusRevision = focusRevision
        self.cancel = cancel
        _addIntro = State(initialValue: session.request.initialEdge == .intro)
        _addOutro = State(initialValue: session.request.initialEdge == .outro)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Transition")
                .font(EditorTheme.dialogTitle)
                .accessibilityAddTraits(.isHeader)
            Text(clip?.displayName ?? "Timeline clip")
                .foregroundStyle(EditorTheme.secondaryText)

            VStack(alignment: .leading, spacing: 12) {
                Toggle(edgeLabel(.intro), isOn: $addIntro)
                    .focused($introFocused)
                if addIntro { transitionControls(edge: .intro) }

                Toggle(edgeLabel(.outro), isOn: $addOutro)
                if addOutro { transitionControls(edge: .outro) }
            }

            if let message = presentedError?.message ?? session.errorMessage {
                Text(message)
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)

            NativeModalActions(helpTopic: .transitions,
                primaryTitle: "Add",
                primaryEnabled: addIntro || addOutro,
                cancel: cancel,
                primary: apply
            )

        }
        .padding(EditorTheme.dialogPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: quitDraft, initial: true) { _, draft in session.hasPendingEdits = draft != initialDraft }
        .task(id: windowActivity == .key ? focusRevision : nil) {
            guard windowActivity == .key, appliedFocusRevision != focusRevision else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            appliedFocusRevision = focusRevision
            introFocused = true
        }
        .pendingQuitDraft(quitDraft, pending: quitDraft != initialDraft,
            validate: { _ = try quitTransitions(); _ = try session.validateProject() },
            apply: { try session.saveForQuit(quitTransitions()) })
    }

    private var quitDraft: QuitDraft {
        QuitDraft(intro: addIntro, outro: addOutro, introVideo: introVideoType, outroVideo: outroVideoType,
            introAudio: introAudioType, outroAudio: outroAudioType, introDuration: introDuration,
            outroDuration: outroDuration, includeIntroAudio: includeIntroAudio, includeOutroAudio: includeOutroAudio)
    }
    private var initialDraft: QuitDraft {
        QuitDraft(intro: request.initialEdge == .intro, outro: request.initialEdge == .outro,
            introVideo: .fade, outroVideo: .fade,
            introAudio: .fade, outroAudio: .fade, introDuration: TransitionDurationInput.defaultText,
            outroDuration: TransitionDurationInput.defaultText, includeIntroAudio: false, includeOutroAudio: false)
    }

    private var applicationName: String {
        if addIntro, !addOutro { return introTransitionName }
        if addOutro, !addIntro { return outroTransitionName }
        return "Transitions"
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
        edge == .intro ? "Intro Transition" : "Outro Transition"
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

    private func quitTransitions() throws -> [TimelineTransition] {
        let intro = addIntro ? TransitionDurationInput.parse(introDuration) : nil
        let outro = addOutro ? TransitionDurationInput.parse(outroDuration) : nil
        guard !(addIntro && intro == nil), !(addOutro && outro == nil) else {
            throw QuitDraftError(message: "Enter a duration greater than zero for each enabled transition.")
        }
        var result: [TimelineTransition] = []
        if let intro { result += makeTransitions(edge: .intro, duration: intro) }
        if let outro { result += makeTransitions(edge: .outro, duration: outro) }
        guard !result.isEmpty else { throw QuitDraftError(message: "The transition clip is no longer available.") }
        return result
    }

    private func apply() {
        do { presentedError = nil; session.apply(try quitTransitions()) }
        catch { showValidation(error.localizedDescription) }
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
