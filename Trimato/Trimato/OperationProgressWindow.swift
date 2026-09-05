import AppKit
import Combine
import SwiftUI

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
        let next = min(90, Int(min(max(progress, 0), 1) * 10) * 10)
        guard next > milestone else { return nil }
        milestone = next
        return "\(title), \(next) percent."
    }

    mutating func finish(
        title: String,
        outcome: OperationProgressOutcome,
        announceCompletion: Bool = true
    ) -> String? {
        guard !finished else { return nil }
        finished = true
        switch outcome {
        case .completed:
            guard announceCompletion else { return nil }
            return determinate ? "\(title), 100 percent, complete." : "\(title), complete."
        case .cancelled:
            return "\(title), cancelled."
        case .failed:
            return "\(title), failed."
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

    @Environment(\.openWindow) private var openWindow
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
               let session = OperationProgressWindowRegistry.shared.session(id: sessionID) {
                session.update(operation)
            } else {
                let sessionID = OperationProgressWindowRegistry.shared.register(operation)
                self.sessionID = sessionID
                openWindow(id: "operation-progress", value: sessionID)
            }
            return
        }

        guard !completionPending, let sessionID,
              let session = OperationProgressWindowRegistry.shared.session(id: sessionID) else { return }
        self.sessionID = nil
        session.finish(outcome: outcome, dismissed: dismissed)
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
        speak(announcements.update(title: operation.title, progress: operation.progress))
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
        speak(announcements.update(title: operation.title, progress: operation.progress))
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
            title: title,
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
final class OperationProgressWindowRegistry: ObservableObject {
    static let shared = OperationProgressWindowRegistry()

    @Published private var sessions: [UUID: OperationProgressWindowSession] = [:]

    func register(_ operation: OperationProgress) -> UUID {
        let session = OperationProgressWindowSession(operation: operation)
        sessions[session.id] = session
        return session.id
    }

    func session(id: UUID) -> OperationProgressWindowSession? {
        sessions[id]
    }

    func remove(id: UUID) {
        sessions[id] = nil
    }
}

struct OperationProgressWindowRoot: View {
    let sessionID: UUID
    @ObservedObject private var registry = OperationProgressWindowRegistry.shared

    var body: some View {
        Group {
            if let session = registry.session(id: sessionID) {
                OperationProgressContent(session: session)
            } else {
                EmptyView()
            }
        }
    }
}

private struct OperationProgressContent: View {
    @ObservedObject var session: OperationProgressWindowSession
    @Environment(\.dismissWindow) private var dismissWindow
    @AccessibilityFocusState private var headingFocused: Bool
    @State private var dismissalScheduled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(session.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)

            if let detail = session.detail {
                Text(detail)
            }

            if let progress = session.progress, progress.isFinite {
                let bounded = min(max(progress, 0), 1)
                ProgressView(value: bounded, total: 1)
                    .accessibilityLabel(session.title)
                    .accessibilityValue("\(Int((bounded * 100).rounded())) percent")
            } else {
                ProgressView()
                    .accessibilityLabel(session.title)
                    .accessibilityValue("In progress")
            }

            if session.canCancel {
                Button("Cancel", action: session.cancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle(session.title)
        .task {
            await Task.yield()
            headingFocused = true
        }
        .onChange(of: session.isFinished, initial: true) { _, finished in
            guard finished, !dismissalScheduled else { return }
            dismissalScheduled = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                session.completeDismissal()
                OperationProgressWindowRegistry.shared.remove(id: session.id)
                dismissWindow(id: "operation-progress", value: session.id)
            }
        }
    }
}
