import AppKit
import Combine
import SwiftUI

nonisolated struct OperationProgressAnnouncements {
    private(set) var milestone = -1
    private(set) var finished = false
    private var determinate = false

    mutating func update(progress: Double?) -> String? {
        guard !finished else { return nil }
        guard let progress, progress.isFinite else {
            guard milestone == -1 else { return nil }
            milestone = 0
            return nil
        }
        determinate = true
        let next = min(90, Int(min(max(progress, 0), 1) * 10) * 10)
        guard next > milestone else { return nil }
        milestone = next
        return "\(next) percent."
    }

    mutating func finish(
        outcome: OperationProgressOutcome,
        announceCompletion: Bool = true
    ) -> String? {
        guard !finished else { return nil }
        finished = true
        switch outcome {
        case .completed:
            guard announceCompletion else { return nil }
            return determinate ? "100 percent, complete." : "Complete."
        case .cancelled:
            return "Cancelled."
        case .failed:
            return "Failed."
        }
    }
}

nonisolated enum OperationProgressOutcome: Equatable {
    case completed
    case cancelled
    case failed
}

struct OperationProgress {
    let title: String
    var progress: Double? = nil
    var detail: String? = nil
    var cancel: (() -> Void)? = nil
    var announceCompletion = true
}

private struct OperationProgressSnapshot: Equatable {
    let title: String?
    let progress: Double?
    let detail: String?
    let canCancel: Bool
    let announceCompletion: Bool
    let outcome: OperationProgressOutcome
    let completionPending: Bool
}

extension View {
    func operationProgress(
        _ operation: OperationProgress?,
        outcome: OperationProgressOutcome = .completed,
        completionPending: Bool = false,
        dismissed: @escaping () -> Void = {}
    ) -> some View {
        modifier(OperationProgressPresenter(
            operation: operation,
            outcome: outcome,
            completionPending: completionPending,
            dismissed: dismissed
        ))
    }
}

private struct OperationProgressPresenter: ViewModifier {
    let operation: OperationProgress?
    let outcome: OperationProgressOutcome
    let completionPending: Bool
    let dismissed: () -> Void

    @State private var sessionID: UUID?

    private var snapshot: OperationProgressSnapshot {
        OperationProgressSnapshot(
            title: operation?.title,
            progress: operation?.progress,
            detail: operation?.detail,
            canCancel: operation?.cancel != nil,
            announceCompletion: operation?.announceCompletion ?? true,
            outcome: outcome,
            completionPending: completionPending
        )
    }

    func body(content: Content) -> some View {
        content.onChange(of: snapshot, initial: true) { _, _ in
            synchronize()
        }
    }

    private func synchronize() {
        if let operation {
            if let sessionID,
               OperationProgressWindowCoordinator.shared.update(operation, id: sessionID) {
            } else {
                let sessionID = OperationProgressWindowCoordinator.shared.present(operation)
                self.sessionID = sessionID
            }
            return
        }

        guard !completionPending, let sessionID else { return }
        self.sessionID = nil
        OperationProgressWindowCoordinator.shared.finish(
            id: sessionID,
            outcome: outcome,
            dismissed: dismissed
        )
    }
}

@MainActor
final class OperationProgressWindowSession: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var title: String
    @Published private(set) var progress: Double?
    @Published private(set) var detail: String?
    @Published private(set) var isFinished = false
    @Published private(set) var outcome = OperationProgressOutcome.completed

    private var cancelAction: (() -> Void)?
    private var dismissedAction: (() -> Void)?
    private var announceCompletion: Bool
    private var announcements = OperationProgressAnnouncements()
    private var wasCancelled = false
    private let postsAnnouncements: Bool

    init(operation: OperationProgress, postsAnnouncements: Bool = true) {
        title = operation.title
        progress = operation.progress
        detail = operation.detail
        cancelAction = operation.cancel
        announceCompletion = operation.announceCompletion
        self.postsAnnouncements = postsAnnouncements
        _ = announcements.update(progress: operation.progress)
    }

    var canCancel: Bool {
        cancelAction != nil && !wasCancelled && !isFinished
    }

    func update(_ operation: OperationProgress) {
        let detailChanged = detail != operation.detail
        title = operation.title
        progress = operation.progress
        detail = operation.detail
        cancelAction = operation.cancel
        announceCompletion = operation.announceCompletion
        if detailChanged, let detail = operation.detail {
            speak(detail)
        }
        speak(announcements.update(progress: operation.progress))
    }

    func cancel() {
        guard canCancel else { return }
        wasCancelled = true
        objectWillChange.send()
        cancelAction?()
    }

    func finish(outcome: OperationProgressOutcome, dismissed: @escaping () -> Void) {
        guard !isFinished else { return }
        self.outcome = wasCancelled ? .cancelled : outcome
        dismissedAction = dismissed
        isFinished = true
        speak(announcements.finish(
            outcome: self.outcome,
            announceCompletion: announceCompletion
        ))
    }

    func completeDismissal() {
        let action = dismissedAction
        dismissedAction = nil
        action?()
    }

    private func speak(_ message: String?) {
        guard postsAnnouncements, let message, NSApp.isActive, let application = NSApp else { return }
        NSAccessibility.post(
            element: application,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.low.rawValue,
            ]
        )
    }
}

@MainActor
final class OperationProgressWindowCoordinator {
    static let shared = OperationProgressWindowCoordinator()

    private var sessions: [UUID: OperationProgressWindowSession] = [:]
    private var windows: [UUID: NativeModalWindowController] = [:]

    func present(_ operation: OperationProgress) -> UUID {
        let session = OperationProgressWindowSession(operation: operation)
        let id = session.id
        let returnWindow = NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow
        let focusRequest = NativeModalFocusRequest()
        let controller = NativeModalWindowController(
            title: operation.title,
            contentSize: NSSize(width: 400, height: operation.detail == nil ? 150 : 190),
            closable: false,
            identifier: .init("Trimato.OperationProgress"),
            rootView: OperationProgressContent(session: session, focusRequest: focusRequest),
            focusRequest: focusRequest,
            returnWindow: returnWindow,
            returned: { [session] in
                session.completeDismissal()
            },
            closed: { [weak self] in
                self?.sessions[id] = nil
                self?.windows[id] = nil
            }
        )
        sessions[id] = session
        windows[id] = controller
        controller.showModal()
        return id
    }

    func update(_ operation: OperationProgress, id: UUID) -> Bool {
        guard let session = sessions[id] else { return false }
        session.update(operation)
        return true
    }

    func finish(
        id: UUID,
        outcome: OperationProgressOutcome,
        dismissed: @escaping () -> Void
    ) {
        sessions[id]?.finish(outcome: outcome, dismissed: dismissed)
    }

    func close(id: UUID) {
        windows[id]?.closeModal()
    }
}

private struct OperationProgressContent: View {
    @ObservedObject var session: OperationProgressWindowSession
    @ObservedObject var focusRequest: NativeModalFocusRequest
    @FocusState private var cancelKeyboardFocused: Bool
    @AccessibilityFocusState private var cancelVoiceOverFocused: Bool
    @AccessibilityFocusState private var progressVoiceOverFocused: Bool
    @State private var dismissalScheduled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(session.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if let detail = session.detail {
                Text(detail)
            }

            if let progress = session.progress, progress.isFinite {
                let bounded = min(max(progress, 0), 1)
                ProgressView(value: bounded, total: 1)
                    .accessibilityFocused($progressVoiceOverFocused)
            } else {
                ProgressView()
                    .accessibilityFocused($progressVoiceOverFocused)
            }

            if session.canCancel {
                Button("Cancel", action: session.cancel)
                    .keyboardShortcut(.cancelAction)
                    .focused($cancelKeyboardFocused)
                    .accessibilityFocused($cancelVoiceOverFocused)
            }
        }
        .padding(24)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle(session.title)
        .onChange(of: focusRequest.revision) { _, revision in
            guard revision > 0 else { return }
            Task { @MainActor in
                await Task.yield()
                if session.canCancel {
                    cancelKeyboardFocused = true
                    cancelVoiceOverFocused = true
                } else {
                    progressVoiceOverFocused = true
                }
            }
        }
        .onChange(of: session.isFinished, initial: true) { _, finished in
            guard finished, !dismissalScheduled else { return }
            dismissalScheduled = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                OperationProgressWindowCoordinator.shared.close(id: session.id)
            }
        }
    }
}
