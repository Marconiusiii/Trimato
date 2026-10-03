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
            _ = try candidate.addTransitionBatch(transitions)
        } catch {
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

    func update(_ transition: TimelineTransition) {
        do {
            let controller = try validateProject()
            try controller.updateTransition(transition)
            controller.dismissTransitionTool()
        } catch { presentError(error.localizedDescription, title: "Transition Could Not Be Updated") }
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
                .font(EditorTheme.dialogTitle)
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
                    Picker("Transition Type", selection: $videoType) {
                        ForEach(VideoTransitionType.allCases.filter { $0 != .fade }) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    .focused($typeFocused)
                    if showsAudioToggle {
                        Toggle(videoType == .fadeOutIn ? "Fade Audio" : "Crossfade Audio", isOn: $includeAudio)
                    }
                } else {
                    Picker("Transition Type", selection: $audioType) {
                        ForEach([AudioTransitionType.crossFade, .fadeOutIn]) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    .focused($typeFocused)
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
        (videoType == .crossDissolve || videoType == .fadeOutIn)
            && selectedEdit?.linkedAudioEdit(in: project) != nil
    }
    private var quitDraft: QuitDraft {
        QuitDraft(edit: selectedEdit, videoType: videoType, audioType: audioType,
                  duration: durationText, includeAudio: includeAudio)
    }
    private var initialDraft: QuitDraft {
        QuitDraft(edit: edits.first, videoType: .crossDissolve, audioType: .crossFade,
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
            duration: duration, includeAudio: showsAudioToggle && includeAudio, in: project)
    }
    private func apply() {
        do { session.apply(try quitTransitions()) }
        catch { session.presentError(error.localizedDescription) }
    }
}
