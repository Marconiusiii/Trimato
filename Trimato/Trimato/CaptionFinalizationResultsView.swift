import SwiftUI

struct CaptionFinalizationResultsView: View {
    let report: CaptionFinalizationReport
    let nativeModalActions: NativeModalActionRegistration
    let showCaption: (UUID) -> Void

    @State private var selection: UUID?
    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Finalize Captions")
                .font(.title2)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)

            Text(summary)

            if let fatalError = report.fatalError {
                Text(fatalError)
                    .textSelection(.enabled)
            } else {
                Table(report.issues, selection: $selection) {
                    TableColumn("Caption") { issue in
                        Text(issue.displayName)
                            .lineLimit(2)
                    }
                    .width(min: 180, ideal: 240)

                    TableColumn("Marked Time") { issue in
                        Text(markedTime(for: issue))
                    }
                    .width(min: 150, ideal: 180)

                    TableColumn("Problem") { issue in
                        Text(problem(for: issue))
                            .lineLimit(3)
                    }
                    .width(min: 250, ideal: 330)
                }
                .frame(width: 720, height: 300)
            }
        }
        .padding(24)
        .frame(minWidth: 520)
        .nativeModalPrimaryAction(
            nativeModalActions,
            enabled: selection != nil,
            action: showSelectedCaption
        )
        .task {
            selection = report.issues.first?.id
            try? await Task.sleep(for: .milliseconds(200))
            headingFocused = true
        }
    }

    private var summary: String {
        if report.fatalError != nil {
            return "Captions could not be finalized."
        }
        let finalized = report.finalizedPassages == 1
            ? "1 passage was finalized."
            : "\(report.finalizedPassages) passages were finalized."
        let remaining = report.issues.count == 1
            ? "1 passage still needs editing."
            : "\(report.issues.count) passages still need editing."
        return "\(finalized) \(remaining)"
    }

    private func markedTime(for issue: CaptionFinalizationIssue) -> String {
        "\(ProjectInfoTimeFormatter.string(issue.markedStart)) to \(ProjectInfoTimeFormatter.string(issue.markedEnd))"
    }

    private func problem(for issue: CaptionFinalizationIssue) -> String {
        guard let required = issue.requiredDuration else { return issue.message }
        let requiredTime = ProjectInfoTimeFormatter.string(ProjectTime(seconds: required))
        let availableTime = ProjectInfoTimeFormatter.string(ProjectTime(seconds: issue.availableDuration))
        return "\(issue.message) Required time: \(requiredTime). Available time: \(availableTime)."
    }

    private func showSelectedCaption() {
        guard let selection else { return }
        showCaption(selection)
    }
}
