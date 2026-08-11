import SwiftUI

struct MediaImportView: View {
    let filename: String
    let status: String
    let progress: Double?
    let cancel: () -> Void

    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Preparing Video")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)

            VStack(alignment: .leading, spacing: 6) {
                Text("File: \(filename)")
                Text(status)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            if let progress {
                ProgressView(value: progress, total: 1)
                    .accessibilityLabel("Import progress")
                    .accessibilityValue("\(Int((progress * 100).rounded())) percent")
            } else {
                ProgressView()
                    .accessibilityLabel("Import progress")
                    .accessibilityValue("In progress")
            }

            HStack {
                Spacer()
                Button("Cancel Import", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(width: 420)
        .padding(24)
        .tint(EditorTheme.accent)
        .background(EditorTheme.controlSurface)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            headingFocused = true
        }
    }
}
