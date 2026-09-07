import SwiftUI

nonisolated enum ProjectCloseDecision { case save, discard, cancel }

struct ProjectCloseConfirmation: View {
    @ObservedObject var coordinator: ProjectWindowSaveCoordinator
    @FocusState private var cancelFocused: Bool
    @AccessibilityFocusState private var cancelVoiceOverFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(coordinator.isApplicationTerminating ? "Save changes before quitting?" : "Save changes to \(coordinator.projectName)?")
                .font(.headline).accessibilityAddTraits(.isHeader)
            Text(coordinator.isApplicationTerminating ? "Save the project and pending editor changes before quitting Trimato." : "The project has changes since your last Save.")
            if let error = coordinator.quitError {
                Text(error).textSelection(.enabled)
            }
            if coordinator.isResolvingClose && coordinator.isApplicationTerminating {
                Text(coordinator.quitCancellationRequested ? "Cancelling quit…" : "Saving changes…")
            }
            HStack {
                Button(coordinator.isApplicationTerminating ? "Quit Without Saving" : "Don’t Save") { coordinator.chooseCloseDecision(.discard) }
                    .disabled(coordinator.isResolvingClose)
                Spacer()
                Button("Cancel") { coordinator.chooseCloseDecision(.cancel) }
                    .keyboardShortcut(.cancelAction)
                    .focused($cancelFocused)
                    .accessibilityFocused($cancelVoiceOverFocused)
                Button(coordinator.isApplicationTerminating ? "Save and Quit" : "Save") { coordinator.chooseCloseDecision(.save) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(coordinator.isResolvingClose)
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled()
        .onAppear { cancelFocused = true; cancelVoiceOverFocused = true }
    }
}
