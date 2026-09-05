import SwiftUI

struct ConfirmationView: View {
    let title: String
    let message: String
    let confirmTitle: String
    let cancel: () -> Void
    let confirm: () -> Void
    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)
            Text(message)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, role: .destructive, action: confirm)
            }
        }
        .padding(24)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            await Task.yield()
            headingFocused = true
        }
    }
}
