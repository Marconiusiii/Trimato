import Combine
import SwiftUI

@MainActor
final class CaptionFinalizationWindowSession: ObservableObject, Identifiable {
    let id: UUID
    let report: CaptionFinalizationReport
    private let reveal: (UUID) -> Void

    init(id: UUID = UUID(), report: CaptionFinalizationReport, reveal: @escaping (UUID) -> Void) {
        self.id = id
        self.report = report
        self.reveal = reveal
    }

    func showCaption(_ cueID: UUID) {
        reveal(cueID)
    }
}

@MainActor
final class CaptionFinalizationWindowRegistry: ObservableObject {
    static let shared = CaptionFinalizationWindowRegistry()

    @Published private var sessions: [UUID: CaptionFinalizationWindowSession] = [:]

    func register(
        report: CaptionFinalizationReport,
        reveal: @escaping (UUID) -> Void
    ) -> UUID {
        let session = CaptionFinalizationWindowSession(report: report, reveal: reveal)
        sessions[session.id] = session
        return session.id
    }

    func session(id: UUID) -> CaptionFinalizationWindowSession? {
        sessions[id]
    }

    func remove(id: UUID) {
        sessions[id] = nil
    }
}

struct CaptionFinalizationWindowRoot: View {
    let sessionID: UUID
    @ObservedObject private var registry = CaptionFinalizationWindowRegistry.shared
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let session = registry.session(id: sessionID) {
                CaptionFinalizationResultsView(
                    report: session.report,
                    showCaption: { cueID in
                        session.showCaption(cueID)
                        close()
                    },
                    done: close
                )
            } else {
                Text("This caption report is no longer available.")
                    .padding(24)
            }
        }
        .onDisappear {
            registry.remove(id: sessionID)
        }
    }

    private func close() {
        registry.remove(id: sessionID)
        dismissWindow(id: "caption-finalization", value: sessionID)
    }
}
