import SwiftUI
import AppKit
import Combine
import OSLog

@MainActor
final class TransitionToolSession: ObservableObject, Identifiable {
    private static let diagnostics = Logger(subsystem: "com.marconius.trimato", category: "Transitions")
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
    @Published private(set) var presentedError: ApplicationMessageDescriptor?
    private var pendingRenderError: String?
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
        do {
            let controller = try validateProject()
            guard !transitions.isEmpty else { throw QuitDraftError(message: "Choose a transition to apply.") }
            var candidate = controller.project
            for transition in transitions {
                let kind = String(describing: transition.kind)
                let leading = transition.leadingClipID.flatMap { candidate.timelineClip(id: $0) }
                let trailing = transition.trailingClipID.flatMap { candidate.timelineClip(id: $0) }
                Self.diagnostics.notice("Apply request: type=\(kind, privacy: .public), duration=\(transition.duration.seconds), outgoingDuration=\(leading?.duration.seconds ?? -1), incomingDuration=\(trailing?.duration.seconds ?? -1), outgoingEnd=\(leading?.segments.last?.sourceRange.end.seconds ?? -1), incomingStart=\(trailing?.segments.first?.sourceRange.start.seconds ?? -1)")
            }
            _ = try candidate.addTransitionBatch(transitions)
        } catch {
            Self.diagnostics.error("Transition preflight rejected: \(error.localizedDescription, privacy: .private)")
            presentError(error.localizedDescription)
            return
        }
        presentedError = nil
        pendingRenderError = nil
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
                Self.diagnostics.error("Transition preparation failed: \(error.localizedDescription, privacy: .private)")
                pendingRenderError = error.localizedDescription
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
        else if let message = pendingRenderError {
            pendingRenderError = nil
            presentError(message)
        } else { controller?.requestToolFocus() }
    }

    func presentError(_ message: String, title: String = "Transition Could Not Be Applied") {
        presentedError = ApplicationMessageDescriptor(title: title,
            message: message, initialFocus: .message)
    }

    func dismissError() {
        presentedError = nil
        guard controller?.transitionToolSession === self else { return }
        controller?.requestToolFocus()
    }

    func saveForQuit(_ transitions: [TimelineTransition]) throws {
        cancelApplication()
        let controller = try validateProject()
        try controller.addTransitions(transitions, selectAddedTransition: !returnsToEditor)
        controller.dismissTransitionTool(restoreFocus: false)
    }

    func update(_ transition: TimelineTransition, linkedAudio: TimelineTransition? = nil, managesLinkedAudio: Bool = false) {
        do {
            let controller = try validateProject()
            try controller.updateTransition(transition, linkedAudio: linkedAudio, managesLinkedAudio: managesLinkedAudio)
            controller.dismissTransitionTool()
        } catch { presentError(error.localizedDescription, title: "Transition Could Not Be Updated") }
    }

    func updateForQuit(_ transition: TimelineTransition, linkedAudio: TimelineTransition? = nil, managesLinkedAudio: Bool = false) throws {
        let controller = try validateProject()
        try controller.updateTransition(transition, linkedAudio: linkedAudio, managesLinkedAudio: managesLinkedAudio)
        controller.dismissTransitionTool(restoreFocus: false)
    }

    func delete() {
        do {
            _ = try validateProject()
            controller?.dismissTransitionTool(restoreFocus: false)
            deleteAction?()
        } catch { presentError(error.localizedDescription, title: "Transition Could Not Be Deleted") }
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
        .applicationMessage(session.presentedError, dismissed: session.dismissError)
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
        let edit: TransitionEdit?
        let videoType: VideoTransitionType
        let audioType: AudioTransitionType
        let audioCurve: AudioCrossFadeCurve
        let duration: String
        let includeAudio: Bool
    }
    @ObservedObject var session: TransitionToolSession
    let focusRevision: Int
    let cancel: () -> Void
    private var project: TrimatoProject { session.project }
    private var request: TransitionRequest { session.request }
    @Environment(\.controlActiveState) private var windowActivity
    @State private var appliedFocusRevision: Int?
    @FocusState private var typeFocused: Bool
    @State private var selectedEdit: TransitionEdit?
    @State private var videoType = VideoTransitionType.crossDissolve
    @State private var audioType = AudioTransitionType.crossFade
    @State private var audioCurve = AudioCrossFadeCurve.linear
    @State private var durationText = TransitionDurationInput.defaultText
    @State private var includeAudio = false

    init(session: TransitionToolSession, focusRevision: Int, cancel: @escaping () -> Void) {
        self.session = session
        self.focusRevision = focusRevision
        self.cancel = cancel
        _selectedEdit = State(initialValue: session.request.availableEdits(in: session.project).first)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Transition")
                .editorFont(.title2, weight: .semibold)
                .accessibilityAddTraits(.isHeader)

            if edits.count > 1 {
                Picker("Edit", selection: $selectedEdit) {
                    ForEach(edits, id: \.self) { edit in
                        Text(edit.description(in: project)).tag(Optional(edit))
                    }
                }
            } else if let selectedEdit {
                Text(selectedEdit.description(in: project))
                    .foregroundStyle(EditorTheme.secondaryText)
            }

            VStack(alignment: .leading, spacing: 12) {
                if track?.kind == .video {
                    VideoTransitionOptions(selection: $videoType, focused: $typeFocused)
                    if showsAudioToggle {
                        Toggle("Include Audio Transition", isOn: $includeAudio)
                        if includeAudio {
                            AudioTransitionOptions(selection: $audioType, curve: $audioCurve,
                                linked: true, focused: $typeFocused)
                        }
                    }
                } else {
                    AudioTransitionOptions(selection: $audioType, curve: $audioCurve,
                        linked: false, focused: $typeFocused)
                }
                TransitionDurationField(text: $durationText)
            }
            .disabled(selectedEdit == nil)

            if selectedEdit == nil {
                Text("No adjoining clips. Move to a shared edit or select a clip with an adjoining clip.")
            }

            Spacer(minLength: 0)
            NativeModalActions(helpTopic: .transitions, primaryTitle: "Add",
                primaryEnabled: selectedEdit != nil, cancel: cancel, primary: apply)
        }
        .padding(EditorTheme.dialogPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: quitDraft, initial: true) { _, draft in session.hasPendingEdits = draft != initialDraft }
        .task(id: windowActivity == .key ? focusRevision : nil) {
            guard windowActivity == .key, appliedFocusRevision != focusRevision else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            appliedFocusRevision = focusRevision
            typeFocused = true
        }
        .pendingQuitDraft(quitDraft, pending: quitDraft != initialDraft,
            validate: { _ = try quitTransitions(); _ = try session.validateProject() },
            apply: { try session.saveForQuit(quitTransitions()) })
    }

    private var track: TimelineTrack? { project.track(id: request.trackID) }
    private var edits: [TransitionEdit] { request.availableEdits(in: project) }
    private var showsAudioToggle: Bool {
        track?.kind == .video && selectedEdit?.linkedAudioEdit(in: project) != nil
    }
    private var quitDraft: QuitDraft {
        QuitDraft(edit: selectedEdit, videoType: videoType, audioType: audioType, audioCurve: audioCurve,
                  duration: durationText, includeAudio: includeAudio)
    }
    private var initialDraft: QuitDraft {
        QuitDraft(edit: edits.first, videoType: .crossDissolve, audioType: .crossFade, audioCurve: .linear,
                  duration: TransitionDurationInput.defaultText, includeAudio: false)
    }
    private func quitTransitions() throws -> [TimelineTransition] {
        guard let duration = TransitionDurationInput.parse(durationText) else {
            throw QuitDraftError(message: "Enter a transition duration greater than zero.")
        }
        guard let selectedEdit, edits.contains(selectedEdit), let track else {
            throw QuitDraftError(message: "Choose two clips that meet at the same edit.")
        }
        return selectedEdit.makeTransitions(trackID: track.id,
            kind: track.kind == .video ? .video(videoType) : .audio(audioType),
            duration: duration, includeAudio: showsAudioToggle && includeAudio,
            audioType: audioType, audioCurve: audioCurve, in: project)
    }
    private func apply() {
        do { session.apply(try quitTransitions()) }
        catch { session.presentError(error.localizedDescription) }
    }
}

struct VideoTransitionOptions: View {
    @Binding var selection: VideoTransitionType
    var focused: FocusState<Bool>.Binding

    var body: some View {
        Picker("Transition Type", selection: Binding(
            get: { selection.family }, set: { if $0 != selection.family { selection = $0.types[0] } }
        )) {
            ForEach(VideoTransitionFamily.allCases) { family in
                Text(family.rawValue).tag(family)
            }
        }
        .focused(focused)
        if selection.family == .fade {
            Picker("Fade Style", selection: Binding(
                get: { selection != .crossDissolve },
                set: { if $0 != (selection != .crossDissolve) { selection = $0 ? .fadeOutIn : .crossDissolve } }
            )) {
                Text("Cross Dissolve").tag(false)
                Text("Fade Through Color").tag(true)
            }
            if selection != .crossDissolve {
                Picker("Fade Color", selection: $selection) {
                    Text("Black").tag(VideoTransitionType.fadeOutIn)
                    Text("White").tag(VideoTransitionType.fadeThroughWhite)
                }
            }
        } else if selection.family != .pixelDissolve {
            Picker(selection.family == .circle ? "Action" : "Direction", selection: $selection) {
                ForEach(selection.family.types) { type in
                    Text(type.optionTitle).tag(type)
                }
            }
        }
    }
}

struct AudioTransitionOptions: View {
    @Binding var selection: AudioTransitionType
    @Binding var curve: AudioCrossFadeCurve
    var linked: Bool
    var focused: FocusState<Bool>.Binding

    var body: some View {
        if linked {
            typePicker
        } else {
            typePicker.focused(focused)
        }
        if selection == .crossFade {
            Picker(linked ? "Audio Fade Curve" : "Fade Curve", selection: $curve) {
                ForEach(AudioCrossFadeCurve.allCases) { curve in
                    Text(curve.title).tag(curve)
                }
            }
        }
    }
    private var typePicker: some View {
        Picker(linked ? "Audio Transition Type" : "Transition Type", selection: $selection) {
            Text("Crossfade").tag(AudioTransitionType.crossFade)
            Text("Fade Out/Fade In").tag(AudioTransitionType.fadeOutIn)
        }
    }
}
