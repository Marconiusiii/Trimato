import SwiftUI

nonisolated enum WorkspaceTool: Equatable {
    case caption, describer, voicer, generator, transitions, quickFade, quickCrossDissolve, quickCrossFade, transitionEditor

    var title: String {
        switch self {
        case .caption: "Captioner"
        case .describer: "Describer"
        case .voicer: "Voicer"
        case .generator: "Generator"
        case .transitions: "Transitions"
        case .quickFade: "Quick Fade"
        case .quickCrossDissolve: "Quick Cross Dissolve"
        case .quickCrossFade: "Quick Cross Fade"
        case .transitionEditor: "Transition Editor"
        }
    }
    var isTransition: Bool {
        switch self {
        case .transitions, .quickFade, .quickCrossDissolve, .quickCrossFade, .transitionEditor: true
        default: false
        }
    }

}

struct ToolPaneCloseAction {
    let title: String
    let action: () -> Void
}

private struct ToolPaneCloseKey: FocusedValueKey {
    typealias Value = ToolPaneCloseAction
}
extension FocusedValues {
    var closeToolPane: ToolPaneCloseAction? {
        get { self[ToolPaneCloseKey.self] }
        set { self[ToolPaneCloseKey.self] = newValue }
    }
}

extension ProjectController {
    var toolHasPendingEdits: Bool {
        switch toolPane {
        case .caption: captionHasPendingEdits?() == true
        case .generator: generatorSession?.hasPendingQuitEdits == true
        case .transitions, .quickFade, .quickCrossDissolve, .quickCrossFade, .transitionEditor:
            transitionToolSession?.hasPendingEdits == true
        case .describer, .voicer:
            recordingSession?.hasPendingQuitEdits == true || recordingSession?.capture.isRecordingRequested == true
                || recordingSession?.preparingRecording == true
        default: false
        }
    }

    func openToolPane(_ tool: WorkspaceTool, replacingCurrent: Bool = false, open: @escaping () -> Void) {
        if toolPane == tool && !replacingCurrent {
            requestToolFocus()
            return
        }
        requestToolChange { [weak self] in
            guard let self else { return }
            closeToolPaneImmediately()
            toolPane = tool
            open()
            requestToolFocus()
        }
    }

    func requestCloseToolPane() {
        guard projectSaveCoordinator?.attachedWindow?.attachedSheet == nil else { return }
        requestToolChange { [weak self] in self?.closeToolPaneImmediately() }
    }

    private func requestToolChange(_ action: @escaping () -> Void) {
        guard !isConfirmingToolClose, recordingSession?.saving != true,
              transitionToolSession?.isApplying != true, transitionToolSession?.completionRequested != true,
              generatorSession?.progress == nil, generatorSession?.hasPendingCompletion != true else { return }
        if toolHasPendingEdits {
            pendingToolAction = action
            isConfirmingToolClose = true
        } else { action() }
    }

    func cancelToolCloseReview() {
        pendingToolAction = nil
        isConfirmingToolClose = false
    }

    func discardToolChanges() {
        // Finish the transition only after the native sheet has dismissed.
        isConfirmingToolClose = false
    }

    func finishToolCloseReview() {
        let action = pendingToolAction
        pendingToolAction = nil
        if let action { action() }
        else { requestToolFocus() }
    }

    func closeToolPaneImmediately() {
        switch toolPane {
        case .caption: closeCaptionEditor()
        case .generator: dismissGenerator()
        case .transitions, .quickFade, .quickCrossDissolve, .quickCrossFade, .transitionEditor: dismissTransitionTool()
        case .describer, .voicer: dismissRecording()
        case nil:
            // Also release sessions created by project-close and test workflows.
            if recordingSession != nil { dismissRecording() }
            if generatorSession != nil { dismissGenerator() }
            if transitionToolSession != nil { dismissTransitionTool() }
        }
        toolPane = nil
    }
}

struct ToolPaneCloseConfirmation: View {
    @ObservedObject var controller: ProjectController
    @FocusState private var cancelFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Discard changes in \(controller.toolPane?.title ?? "this tool")?")
                .font(.headline).accessibilityAddTraits(.isHeader)
            Text("The unfinished changes have not been applied to the project.")
            HStack {
                Button("Discard Changes", role: .destructive, action: controller.discardToolChanges)
                Spacer()
                Button("Cancel", action: controller.cancelToolCloseReview)
                    .keyboardShortcut(.cancelAction)
                    .focused($cancelFocused)
            }
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled()
        .task {
            await Task.yield()
            cancelFocused = true
        }
    }
}
