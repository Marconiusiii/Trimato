import AppKit
import Combine
import SwiftUI

@MainActor
final class CaptionEditorWindowCoordinator: ObservableObject {
    private enum FocusOrigin {
        case editor
        case timeline(CaptionCue.ID)
    }

    private weak var controller: ProjectController?
    @Published private(set) var activeSession: CaptionEditorWindowSession?

    init(controller: ProjectController) {
        self.controller = controller
    }

    func openNew() {
        guard let controller, let range = controller.captionDraftRange else {
            controller?.presentedError = ProjectPresentedError(
                title: "Caption Needs In and Out Points",
                message: "Mark an In point and an Out point in the Editor before adding a caption."
            )
            return
        }
        open(cue: nil, range: range, origin: .editor)
    }

    func open(cue: CaptionCue) {
        if controller?.project.descriptionTranscriptTrack?.captionCues.contains(where: { $0.id == cue.id }) == true {
            controller?.requestRecording(.audioDescription, cue: cue)
            return
        }
        open(
            cue: cue,
            range: ProjectTimeRange(start: cue.start, duration: cue.duration),
            origin: .timeline(cue.id)
        )
    }

    func close() {
        activeSession?.cancel()
    }

    private func open(cue: CaptionCue?, range: ProjectTimeRange, origin: FocusOrigin) {
        guard let controller else { return }
        controller.openToolPane(.caption) { [weak self, weak controller] in
            guard let self, let controller else { return }
            controller.stopCaptionPlayback()
            let session = CaptionEditorWindowSession(
                cue: cue,
                range: range,
                save: { [weak controller] text in
                    guard let controller else { return }
                    if var cue {
                        cue.text = text
                        cue.identifier = nil
                        cue.webVTTSettings = nil
                        try controller.updateCaptionCue(cue)
                    } else {
                        _ = try controller.addCaptionCue(start: range.start, end: range.end, text: text)
                        controller.clearCaptionMarkers()
                    }
                },
                play: { [weak controller] in controller?.playCaptionRange(range) },
                finished: { [weak self] in self?.finish() }
            )
            session.closeAction = { [weak self, weak controller, weak session] in
                session?.finishOnce()
                self?.activeSession = nil
                controller?.captionHasPendingEdits = nil
                controller?.setCaptionEditorOpen(false)
                if controller?.toolPane == .caption { controller?.toolPane = nil }
                Task { @MainActor [weak self, weak controller] in
                    await Task.yield()
                    guard controller?.toolPane == nil else { return }
                    self?.restoreFocus(origin: origin)
                }
            }
            self.activeSession = session
            controller.captionHasPendingEdits = { [weak session] in session?.hasPendingQuitEdits == true }
            controller.setCaptionEditorOpen(true)
        }
    }

    private func finish() {
        controller?.stopCaptionPlayback()
    }

    private func restoreFocus(origin: FocusOrigin) {
        switch origin {
        case .editor:
            controller?.requestEditorFocusRestore()
        case .timeline(let cueID):
            controller?.requestTimelineFocusRestore(to: .caption(cueID))
        }
    }

}

@MainActor
final class CaptionEditorWindowSession: ObservableObject, Identifiable {
    let id = UUID()
    let title: String
    let range: ProjectTimeRange
    let actionTitle: String
    @Published var text: String
    @Published private(set) var errorMessage: String?
    var closeAction: (() -> Void)?

    private let initialText: String
    private let saveAction: (String) throws -> Void
    private let playAction: () -> Void
    private var finishedAction: (() -> Void)?

    init(
        cue: CaptionCue?,
        range: ProjectTimeRange,
        save: @escaping (String) throws -> Void,
        play: @escaping () -> Void,
        finished: @escaping () -> Void
    ) {
        title = cue == nil ? "New Caption" : "Edit Caption"
        actionTitle = cue == nil ? "Add Caption" : "Update Caption"
        text = cue?.text ?? ""
        initialText = cue?.text ?? ""
        self.range = range
        saveAction = save
        playAction = play
        finishedAction = finished
    }

    var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasPendingQuitEdits: Bool { text != initialText }
    func saveForQuit() throws {
        guard canSave else { throw QuitDraftError(message: "Enter caption text before saving.") }
        try saveAction(text)
    }

    func save() {
        guard canSave else { return }
        do {
            try saveAction(text)
            closeAction?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func play() { playAction() }

    func insert(_ insertion: String) {
        if text.isEmpty {
            text = insertion
        } else if text.last?.isWhitespace == true {
            text += insertion
        } else {
            text += " " + insertion
        }
    }

    func dismissError() { errorMessage = nil }
    func cancel() { closeAction?() }

    func finishOnce() {
        closeAction = nil
        let action = finishedAction
        finishedAction = nil
        action?()
    }
}

struct CaptionEditorView: View {
    @ObservedObject var session: CaptionEditorWindowSession
    let focusRevision: Int
    let cancel: () -> Void
    @Environment(\.controlActiveState) private var windowActivity
    @State private var appliedFocusRevision: Int?
    @FocusState private var textFocused: Bool

    private var actions: some View {
        HStack {
            Spacer()
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
            NativeDefaultButton(
                title: session.actionTitle,
                isEnabled: session.canSave,
                action: session.save
            )
            ContextualHelpButton(topic: .captioner)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            actions.padding(EditorTheme.dialogPadding)
        }
        .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(session.title)
                .font(EditorTheme.dialogTitle)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 8) {
                Text("In Time: \(ProjectTimecodeFormatter.string(session.range.start))")
                    .monospacedDigit()
                Text("Out Time: \(ProjectTimecodeFormatter.string(session.range.end))")
                    .monospacedDigit()
            }

            TextEditor(text: $session.text)
                .font(.body)
                .focused($textFocused)
                .accessibilityLabel("Caption Text")
                .frame(minHeight: 100, idealHeight: 220, maxHeight: .infinity)

            Menu("Insert Caption Description") {
                Button("Music Description") { session.insert("[music description]") }
                Button("Sound Description") { session.insert("[sound description]") }
                Button("Lyrics") { session.insert("♪ lyrics ♪") }
            }

            if let errorMessage = session.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Caption Could Not Be Saved")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(errorMessage)
                    Button("Dismiss Error", action: session.dismissError)
                }
            }

            Button("Play Selection", action: session.play)

        }
        .padding(EditorTheme.dialogPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pendingQuitDraft(session.text, pending: session.hasPendingQuitEdits,
            validate: { if !session.canSave { throw QuitDraftError(message: "Enter caption text before saving.") } },
            apply: { try session.saveForQuit(); session.cancel() })
        .navigationTitle(session.title)
        .task(id: windowActivity == .key ? focusRevision : nil) {
            guard windowActivity == .key, appliedFocusRevision != focusRevision else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            appliedFocusRevision = focusRevision
            textFocused = true
        }
    }
}
