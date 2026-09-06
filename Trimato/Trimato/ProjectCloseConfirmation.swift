import SwiftUI

nonisolated enum ProjectCloseDecision { case save, discard, cancel }

struct ProjectCloseConfirmation: View {
    @ObservedObject var coordinator: ProjectWindowSaveCoordinator
    @FocusState private var cancelFocused: Bool
    @AccessibilityFocusState private var cancelVoiceOverFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save changes to \(coordinator.projectName)?")
                .font(.headline).accessibilityAddTraits(.isHeader)
            Text("The project has changes since your last Save.")
            HStack {
                Button("Don’t Save") { coordinator.chooseCloseDecision(.discard) }
                Spacer()
                Button("Cancel") { coordinator.chooseCloseDecision(.cancel) }
                    .keyboardShortcut(.cancelAction)
                    .focused($cancelFocused)
                    .accessibilityFocused($cancelVoiceOverFocused)
                Button("Save") { coordinator.chooseCloseDecision(.save) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled()
        .onAppear { cancelFocused = true; cancelVoiceOverFocused = true }
    }
}
