import AppKit
import Accessibility
import Combine
import SwiftUI

// Loading and completion use the same attributed announcement API.
// Priority supersedes expendable progress; it is not a system queue flush.
nonisolated enum ClipLoadingSpeech {
    static func announcement(_ message: String, completed: Bool) -> AttributedString {
        var announcement = AttributedString(message)
        announcement.accessibilitySpeechAnnouncementPriority = completed ? .high : .low
        return announcement
    }

    @MainActor static func post(_ announcement: AttributedString) {
        guard NSApp?.isActive == true, !AudioCaptureSession.suppressesAnnouncements else { return }
        AccessibilityNotification.Announcement(announcement).post()
    }
}

nonisolated struct OperationProgressAnnouncements {
    private(set) var milestone = -1
    private(set) var finished = false
    private var determinate = false
    private var stage: String?

    mutating func update(progress: Double?, stage: String? = nil) -> String? {
        guard !finished else { return nil }
        if self.stage != stage {
            self.stage = stage
            milestone = -1
            determinate = false
        }
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
    var announcesUpdates = true
    // Clip-loading stages identify measured work without changing native status text.
    var progressStage: String? = nil

    static func clipLoading(progress: Double?, stage: String?, cancel: @escaping () -> Void) -> Self {
        OperationProgress(title: "Preparing Clip", progress: progress, cancel: cancel,
                          announceCompletion: false, progressStage: stage ?? "Preparing Clip")
    }
}

private struct OperationProgressSnapshot: Equatable {
    let title: String?
    let progress: Double?
    let detail: String?
    let progressStage: String?
    let canCancel: Bool
    let announceCompletion: Bool
    let announcesUpdates: Bool
    let outcome: OperationProgressOutcome
    let completionPending: Bool
    let returnWindowNumber: Int?
    let waitsForReturnWindow: Bool
}

extension View {
    func operationProgress(
        _ operation: OperationProgress?,
        outcome: OperationProgressOutcome = .completed,
        completionPending: Bool = false,
        returnWindow: NSWindow? = nil,
        waitsForReturnWindow: Bool = false,
        dismissed: @escaping () -> Void = {}
    ) -> some View {
        modifier(OperationProgressPresenter(
            operation: operation,
            outcome: outcome,
            completionPending: completionPending,
            returnWindow: returnWindow,
            waitsForReturnWindow: waitsForReturnWindow,
            dismissed: dismissed
        ))
    }
}

private struct OperationProgressPresenter: ViewModifier {
    let operation: OperationProgress?
    let outcome: OperationProgressOutcome
    let completionPending: Bool
    let returnWindow: NSWindow?
    let waitsForReturnWindow: Bool
    let dismissed: () -> Void

    @State private var sessionID: UUID?
    @State private var awaitingCompletion = false

    private var snapshot: OperationProgressSnapshot {
        OperationProgressSnapshot(
            title: operation?.title,
            progress: operation?.progress,
            detail: operation?.detail,
            progressStage: operation?.progressStage,
            canCancel: operation?.cancel != nil,
            announceCompletion: operation?.announceCompletion ?? true,
            announcesUpdates: operation?.announcesUpdates ?? true,
            outcome: outcome,
            completionPending: completionPending,
            returnWindowNumber: returnWindow?.windowNumber,
            waitsForReturnWindow: waitsForReturnWindow
        )
    }

    func body(content: Content) -> some View {
        content.onChange(of: snapshot, initial: true) { _, _ in
            synchronize()
        }
    }

    private func synchronize() {
        if operation != nil || completionPending { awaitingCompletion = true }
        if let operation {
            guard !waitsForReturnWindow || returnWindow != nil else { return }
            if let sessionID,
               OperationProgressWindowCoordinator.shared.update(operation, id: sessionID) {
            } else {
                let sessionID = OperationProgressWindowCoordinator.shared.present(
                    operation,
                    returnWindow: returnWindow
                )
                self.sessionID = sessionID
            }
            return
        }

        guard !completionPending, awaitingCompletion else { return }
        awaitingCompletion = false
        guard let sessionID else {
            dismissed()
            return
        }
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
    private let announcementHandler: ((AttributedString) -> Void)?
    private let announcesUpdates: Bool
    private var progressStage: String?

    init(operation: OperationProgress, postsAnnouncements: Bool = true,
         announcementHandler: ((AttributedString) -> Void)? = nil) {
        self.announcementHandler = announcementHandler
        title = operation.title
        progress = operation.progress
        detail = operation.detail
        cancelAction = operation.cancel
        announceCompletion = operation.announceCompletion
        self.postsAnnouncements = postsAnnouncements
        announcesUpdates = operation.announcesUpdates
        progressStage = operation.progressStage
        _ = announcements.update(progress: operation.progress, stage: operation.progressStage)
    }

    var usesStageProgress: Bool { progressStage != nil }

    var canCancel: Bool {
        cancelAction != nil && !wasCancelled && !isFinished
    }

    func update(_ operation: OperationProgress) {
        guard !isFinished else { return }
        let detailChanged = detail != operation.detail
        title = operation.title
        progress = operation.progress
        detail = operation.detail
        cancelAction = operation.cancel
        announceCompletion = operation.announceCompletion
        progressStage = operation.progressStage
        let milestone = announcements.update(progress: operation.progress, stage: operation.progressStage)
        if announcesUpdates {
            if let stage = progressStage {
                if let milestone { speak("\(stage), \(milestone)") }
                // Brief stages are internal state, not additional native status text.
            } else {
                if detailChanged, let detail = operation.detail { speak(detail) }
                speak(milestone)
            }
        }
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
        guard let message else { return }
        if progressStage != nil {
            let announcement = ClipLoadingSpeech.announcement(message, completed: isFinished)
            if let announcementHandler { announcementHandler(announcement); return }
            if postsAnnouncements { ClipLoadingSpeech.post(announcement) }
            return
        }
        var announcement = AttributedString(message)
        announcement.accessibilitySpeechAnnouncementPriority = announcesUpdates ? .low : .default
        if let announcementHandler { announcementHandler(announcement); return }
        guard postsAnnouncements, let application = NSApp, application.isActive else { return }
        if !announcesUpdates {
            AccessibilityNotification.Announcement(announcement).post()
            return
        }
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

    func present(_ operation: OperationProgress, returnWindow explicitReturnWindow: NSWindow? = nil) -> UUID {
        let session = OperationProgressWindowSession(operation: operation)
        let id = session.id
        let returnWindow = explicitReturnWindow ?? NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow
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

            if session.usesStageProgress {
                ProgressView(value: session.progress.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }, total: 1)
                    .progressViewStyle(.linear)
                    .accessibilityFocused($progressVoiceOverFocused)
            } else if let progress = session.progress, progress.isFinite {
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

// Clip preparation belongs to its editor window. Keep its entry gate closed until
// SwiftUI confirms dismissal, including when preparation finishes before appearance.
@MainActor
final class ClipPreparationSheetPresentation: ObservableObject {
    @Published private(set) var session: OperationProgressWindowSession?
    @Published var isPresented = false
    private var awaitingCompletion = false
    private let postsAnnouncements: Bool

    init(postsAnnouncements: Bool = true) {
        self.postsAnnouncements = postsAnnouncements
    }

    func synchronize(operation: OperationProgress?, outcome: OperationProgressOutcome,
                     completionPending: Bool, dismissed: @escaping () -> Void) {
        if operation != nil || completionPending { awaitingCompletion = true }
        if let operation {
            if let session {
                // A new request can be presented after the current sheet dismisses.
                guard !session.isFinished else { return }
                session.update(operation)
            } else {
                session = OperationProgressWindowSession(operation: operation, postsAnnouncements: postsAnnouncements)
                isPresented = true
                ClipEntryDiagnostics.record("preparation.sheetRequested id=\(session!.id)")
            }
            return
        }
        guard !completionPending, awaitingCompletion else { return }
        awaitingCompletion = false
        guard let session else {
            dismissed()
            return
        }
        session.finish(outcome: outcome, dismissed: dismissed)
        ClipEntryDiagnostics.record("preparation.finished id=\(session.id) outcome=\(outcome)")
    }

    func sheetDismissed() {
        let completed = session
        session = nil
        isPresented = false
        ClipEntryDiagnostics.record("preparation.nativeDismissal id=\(String(describing: completed?.id))")
        completed?.completeDismissal()
    }
}

extension View {
    func clipPreparationSheet(_ operation: OperationProgress?,
                              outcome: OperationProgressOutcome,
                              completionPending: Bool = false,
                              dismissed: @escaping () -> Void) -> some View {
        modifier(ClipPreparationSheetPresenter(operation: operation, outcome: outcome,
            completionPending: completionPending, dismissed: dismissed))
    }
}

private struct ClipPreparationSheetPresenter: ViewModifier {
    let operation: OperationProgress?
    let outcome: OperationProgressOutcome
    let completionPending: Bool
    let dismissed: () -> Void
    @StateObject private var presentation = ClipPreparationSheetPresentation()

    private var snapshot: OperationProgressSnapshot {
        OperationProgressSnapshot(title: operation?.title, progress: operation?.progress,
            detail: operation?.detail, progressStage: operation?.progressStage,
            canCancel: operation?.cancel != nil, announceCompletion: operation?.announceCompletion ?? false,
            announcesUpdates: operation?.announcesUpdates ?? true, outcome: outcome,
            completionPending: completionPending, returnWindowNumber: nil, waitsForReturnWindow: false)
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $presentation.isPresented, onDismiss: presentation.sheetDismissed) {
                if let session = presentation.session {
                    ClipPreparationSheetContent(session: session)
                        .interactiveDismissDisabled()
                }
            }
            .onChange(of: snapshot, initial: true) { _, _ in synchronize() }
            .onChange(of: presentation.session?.id) { _, sessionID in
                // Re-read current loading state on the next view update. A sheet's
                // stored onDismiss closure must not replay its old operation.
                if sessionID == nil { synchronize() }
            }
    }

    private func synchronize() {
        presentation.synchronize(operation: operation, outcome: outcome,
            completionPending: completionPending, dismissed: dismissed)
    }
}

private struct ClipPreparationSheetContent: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: OperationProgressWindowSession
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Preparing Clip").font(.headline)
            ProgressView(value: session.progress.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }, total: 1)
                .progressViewStyle(.linear)
                .accessibilityLabel("Preparing Clip")
            if session.canCancel {
                Button("Cancel", action: session.cancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: session.isFinished, initial: true) { _, finished in
            if finished {
                ClipEntryDiagnostics.record("preparation.requestNativeDismissal id=\(session.id)")
                dismiss()
            }
        }
    }
}
