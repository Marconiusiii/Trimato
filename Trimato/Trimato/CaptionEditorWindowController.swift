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
    private weak var projectWindow: NSWindow?
    private var activeSession: CaptionEditorWindowSession?
    private var activeWindow: NativeModalWindowController?

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
        guard activeWindow == nil, let controller else { return }
        controller.stopCaptionPlayback()
        projectWindow = currentProjectWindow

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
        let focusRequest = NativeModalFocusRequest()
        let modalWindow = NativeModalWindowController(
            title: session.title,
            contentSize: NSSize(width: 560, height: 390),
            rootView: CaptionEditorView(session: session, focusRequest: focusRequest),
            focusRequest: focusRequest,
            returnWindow: projectWindow,
            returned: { [weak self] in self?.restoreFocus(origin: origin) },
            closed: { [weak self, weak session] in
                session?.finishOnce()
                self?.activeSession = nil
                self?.activeWindow = nil
            }
        )
        session.closeAction = { [weak modalWindow] in modalWindow?.closeModal() }
        activeSession = session
        activeWindow = modalWindow
        controller.setCaptionEditorOpen(true)
        modalWindow.showModal()
    }

    private func finish() {
        controller?.stopCaptionPlayback()
        controller?.setCaptionEditorOpen(false)
        projectWindow = nil
    }

    private func restoreFocus(origin: FocusOrigin) {
        switch origin {
        case .editor:
            controller?.requestEditorFocusRestore()
        case .timeline(let cueID):
            controller?.requestTimelineFocusRestore(to: .caption(cueID))
        }
    }

    private var currentProjectWindow: NSWindow? {
        if let keyWindow = NSApp.keyWindow { return keyWindow.sheetParent ?? keyWindow }
        if let mainWindow = NSApp.mainWindow { return mainWindow.sheetParent ?? mainWindow }
        return nil
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
        self.range = range
        saveAction = save
        playAction = play
        finishedAction = finished
    }

    var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
    @ObservedObject var focusRequest: NativeModalFocusRequest
    @FocusState private var textFocused: Bool
    @AccessibilityFocusState private var textVoiceOverFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(session.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 24) {
                LabeledContent("In") {
                    Text(ProjectTimecodeFormatter.string(session.range.start)).monospacedDigit()
                }
                LabeledContent("Out") {
                    Text(ProjectTimecodeFormatter.string(session.range.end)).monospacedDigit()
                }
            }

            TextEditor(text: $session.text)
                .font(.body)
                .focused($textFocused)
                .accessibilityFocused($textVoiceOverFocused)
                .accessibilityLabel("Caption Text")
                .frame(minHeight: 150)

            if let errorMessage = session.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Caption Could Not Be Saved")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(errorMessage)
                    Button("Dismiss Error", action: session.dismissError)
                }
            }

            HStack(spacing: 8) {
                Button("Play Selection", action: session.play)
                Menu("Insert Description") {
                    Button("Music Description") { session.insert("[music description]") }
                    Button("Sound Description") { session.insert("[sound description]") }
                    Button("Lyrics") { session.insert("♪ lyrics ♪") }
                }
                Spacer()
                Button("Cancel", action: session.cancel)
                    .keyboardShortcut(.cancelAction)
                NativeDefaultButton(
                    title: session.actionTitle,
                    isEnabled: session.canSave,
                    action: session.save
                )
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 350)
        .navigationTitle(session.title)
        .onChange(of: focusRequest.revision) { _, revision in
            guard revision > 0 else { return }
            Task { @MainActor in
                await Task.yield()
                textFocused = true
                textVoiceOverFocused = true
            }
        }
    }
}
