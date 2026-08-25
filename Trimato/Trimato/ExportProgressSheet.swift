import SwiftUI

struct ExportProgressSheet: View {
    let title: String
    let progress: Double?
    let cancel: () -> Void

    @AccessibilityFocusState private var progressFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            if let progress {
                ProgressView(value: min(max(progress, 0), 1), total: 1)
                    .accessibilityLabel("Export progress")
                    .accessibilityValue(Self.accessibilityValue(progress))
                    .accessibilityFocused($progressFocused)
            } else {
                ProgressView()
                    .accessibilityLabel("Export progress")
                    .accessibilityValue("In progress")
                    .accessibilityFocused($progressFocused)
            }

            HStack {
                Spacer()
                Button("Cancel Export", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(width: 420)
        .padding(24)
        .interactiveDismissDisabled()
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            progressFocused = true
        }
    }

    nonisolated static func accessibilityValue(_ progress: Double) -> String {
        let bounded = min(max(progress, 0), 1)
        let percentage = min(Int(bounded * 20) * 5, 100)
        return "\(percentage) percent"
    }
}
