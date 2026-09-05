import AppKit
import Combine
import SwiftUI

@MainActor
final class CaptionFinalizationWindowSession: ObservableObject, Identifiable {
    let id = UUID()
    let report: CaptionFinalizationReport
    private let reveal: (UUID) -> Void
    private var pendingRevealID: UUID?

    init(report: CaptionFinalizationReport, reveal: @escaping (UUID) -> Void) {
        self.report = report
        self.reveal = reveal
    }

    func selectCaption(_ cueID: UUID) {
        pendingRevealID = cueID
    }

    func revealSelectedCaption() {
        guard let pendingRevealID else { return }
        reveal(pendingRevealID)
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
        let focusRequest = NativeModalFocusRequest()
        let controller = NativeModalWindowController(
            title: "Finalize Captions",
            contentSize: NSSize(width: 780, height: 460),
            resizable: true,
            rootView: CaptionFinalizationResultsView(
                report: report,
                focusRequest: focusRequest,
                showCaption: { [weak session] cueID in
                    session?.selectCaption(cueID)
                    CaptionFinalizationWindowCoordinator.shared.dismiss(id: id)
                },
                done: { CaptionFinalizationWindowCoordinator.shared.dismiss(id: id) }
            ),
            focusRequest: focusRequest,
            returnWindow: parentWindow,
            returned: { [session] in
                session.revealSelectedCaption()
            },
            closed: { [weak self] in
                self?.sessions[id] = nil
                self?.windows[id] = nil
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
