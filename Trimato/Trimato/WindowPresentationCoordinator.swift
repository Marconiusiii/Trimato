import AppKit
import Combine
import SwiftUI

@MainActor
final class CaptionFinalizationWindowSession: ObservableObject, Identifiable {
    let id = UUID()
    let report: CaptionFinalizationReport
    private let reveal: (UUID) -> Void

    init(report: CaptionFinalizationReport, reveal: @escaping (UUID) -> Void) {
        self.report = report
        self.reveal = reveal
    }

    func showCaption(_ cueID: UUID) {
        reveal(cueID)
    }
}

@MainActor
final class CaptionFinalizationWindowCoordinator {
    static let shared = CaptionFinalizationWindowCoordinator()

    private var sessions: [UUID: CaptionFinalizationWindowSession] = [:]
    private var windows: [UUID: NativeModalWindowController] = [:]

    func present(
        report: CaptionFinalizationReport,
        parentWindow: NSWindow?,
        reveal: @escaping (UUID) -> Void
    ) {
        let session = CaptionFinalizationWindowSession(report: report, reveal: reveal)
        let id = session.id
        let controller = NativeModalWindowController(
            title: "Finalize Captions",
            contentSize: NSSize(width: 780, height: 460),
            resizable: true,
            rootView: CaptionFinalizationResultsView(
                report: report,
                showCaption: { [weak session] cueID in
                    session?.showCaption(cueID)
                    CaptionFinalizationWindowCoordinator.shared.dismiss(id: id)
                },
                done: { CaptionFinalizationWindowCoordinator.shared.dismiss(id: id) }
            ),
            closed: { [weak self, weak parentWindow] in
                self?.sessions[id] = nil
                self?.windows[id] = nil
                parentWindow?.makeKeyAndOrderFront(nil)
            }
        )
        sessions[id] = session
        windows[id] = controller
        controller.showModal()
    }

    func dismiss(id: UUID) {
        windows[id]?.closeModal()
    }
}
