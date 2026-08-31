import AppKit
import SwiftUI

/// Speech is independent of the focused control. A new operation owns a fresh ledger.
nonisolated struct OperationProgressAnnouncements {
    private(set) var milestone = -1
    private(set) var finished = false
    private var determinate = false

    mutating func update(title: String, progress: Double?) -> String? {
        guard !finished else { return nil }
        guard let progress, progress.isFinite else {
            guard milestone == -1 else { return nil }
            milestone = 0
            return "\(title)."
        }
        determinate = true
        // Rendering can finish before validation and installation. Only finish() says 100%.
        let next = min(90, Int(min(max(progress, 0), 1) * 10) * 10)
        guard next > milestone else { return nil }
        milestone = next
        return "\(title), \(next) percent."
    }

    mutating func finish(title: String, outcome: OperationProgressOutcome) -> String? {
        guard !finished else { return nil }
        finished = true
        switch outcome {
        case .completed: return determinate ? "\(title), 100 percent, complete." : "\(title), complete."
        case .cancelled: return "\(title), cancelled."
        case .failed: return "\(title), failed."
        }
    }
}

nonisolated enum OperationProgressOutcome { case completed, cancelled, failed }

struct OperationProgress {
    let title: String
    var progress: Double? = nil
    var detail: String? = nil
    var cancel: (() -> Void)? = nil
}

extension View {
    func operationProgress(
        _ operation: OperationProgress?,
        outcome: OperationProgressOutcome = .completed,
        completionPending: Bool = false,
        dismissed: @escaping () -> Void = {}
    ) -> some View {
        background(OperationProgressBridge(operation: operation, outcome: outcome, completionPending: completionPending, dismissed: dismissed))
    }
}

private struct OperationProgressContent: View {
    let operation: OperationProgress
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(operation.title).font(.headline).accessibilityAddTraits(.isHeader)
            if let detail = operation.detail { Text(detail) }
            if let progress = operation.progress, progress.isFinite {
                ProgressView(value: min(max(progress, 0), 1), total: 1)
                    .accessibilityLabel(operation.title)
            } else {
                ProgressView(operation.title)
            }
            if let cancel = operation.cancel {
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A document-modal NSPanel is a separate window, never an overlay in the editor.
/// If a configuration sheet is closing, wait for its native end-sheet notification.
private struct OperationProgressBridge: NSViewRepresentable {
    let operation: OperationProgress?
    let outcome: OperationProgressOutcome
    let completionPending: Bool
    let dismissed: () -> Void

    func makeNSView(context: Context) -> ProgressAnchor {
        let view = ProgressAnchor()
        view.owner = context.coordinator
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: ProgressAnchor, context: Context) {
        context.coordinator.update(operation, outcome: outcome, completionPending: completionPending, dismissed: dismissed, parent: view.window)
    }

    static func dismantleNSView(_ view: ProgressAnchor, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class ProgressAnchor: NSView {
        weak var owner: Coordinator?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            owner?.attach(window)
        }
    }

    @MainActor final class Coordinator {
        private weak var parent: NSWindow?
        private var panel: NSPanel?
        private var hosting: NSHostingController<OperationProgressContent>?
        private var pending: OperationProgress?
        private var activeTitle: String?
        private var activeDetail: String?
        private var announcements = OperationProgressAnnouncements()
        private var observer: NSObjectProtocol?
        private var cancelled = false

        func attach(_ parent: NSWindow?) {
            guard self.parent !== parent else { presentIfPossible(); return }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            self.parent = parent
            if let parent {
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didEndSheetNotification, object: parent, queue: .main
                ) { [weak self] _ in
                    // Run after AppKit has finished removing the old sheet.
                    Task { @MainActor [weak self] in self?.presentIfPossible() }
                }
            }
            presentIfPossible()
        }

        func update(_ operation: OperationProgress?, outcome: OperationProgressOutcome, completionPending: Bool,
                    dismissed: @escaping () -> Void, parent: NSWindow?) {
            pending = operation
            guard let operation else {
                attach(parent)
                guard let title = activeTitle else {
                    if completionPending { Task { @MainActor in dismissed() } }
                    return
                }
                activeTitle = nil
                closePanel()
                speak(announcements.finish(title: title, outcome: cancelled ? .cancelled : outcome))
                Task { @MainActor in dismissed() }
                return
            }
            if activeTitle == nil {
                activeTitle = operation.title
                activeDetail = operation.detail
                cancelled = false
                announcements = OperationProgressAnnouncements()
            }
            if activeDetail != operation.detail {
                activeDetail = operation.detail
                announcements = OperationProgressAnnouncements()
                if panel != nil { speak(operation.detail) }
            }
            attach(parent)
            presentIfPossible()
            panel?.title = operation.title
            hosting?.rootView = OperationProgressContent(operation: displayed(operation))
            if panel != nil { speak(announcements.update(title: operation.title, progress: operation.progress)) }
        }

        private func displayed(_ operation: OperationProgress) -> OperationProgress {
            var result = operation
            if let cancel = operation.cancel {
                result.cancel = { [weak self] in
                    guard let self, !self.cancelled else { return }
                    self.cancelled = true
                    cancel()
                }
            }
            return result
        }

        private func presentIfPossible() {
            guard panel == nil, let operation = pending, let parent,
                  parent.attachedSheet == nil else { return }
            let hosting = NSHostingController(rootView: OperationProgressContent(operation: displayed(operation)))
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 448, height: 180),
                                styleMask: [.titled], backing: .buffered, defer: false)
            panel.title = operation.title
            panel.contentViewController = hosting
            panel.isReleasedWhenClosed = false
            self.hosting = hosting
            self.panel = panel
            parent.beginSheet(panel)
            speak(announcements.update(title: operation.title, progress: operation.progress))
        }

        private func closePanel() {
            guard let panel else { return }
            panel.sheetParent?.endSheet(panel)
            panel.orderOut(nil)
            self.panel = nil
            hosting = nil
        }

        func invalidate() {
            pending = nil
            activeTitle = nil
            closePanel()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }

        private func speak(_ message: String?) {
            guard let message, let application = NSApp else { return }
            NSAccessibility.post(element: application, notification: .announcementRequested,
                                 userInfo: [.announcement: message,
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }
}
