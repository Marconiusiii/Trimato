import AppKit
import Accessibility
import Combine
import SwiftUI

/// Opening is not complete merely because views were installed. Keyboard entry
/// needs a matching destination's confirmation; accessibility focus is separate.
nonisolated struct ProjectOpeningEntry: Equatable {
    enum Target: Equatable { case projectSource, importFiles }
    enum Phase: Equatable {
        case preparing, reviewingFailure(Target), pending(Target), entered(Target), cancelled
    }
    private(set) var phase: Phase

    init(required: Bool) { phase = required ? .preparing : .cancelled }

    var pendingTarget: Target? {
        if case .pending(let target) = phase { return target }
        return nil
    }

    mutating func install(target: Target, hasFailure: Bool) {
        guard phase == .preparing else { return }
        phase = hasFailure ? .reviewingFailure(target) : .pending(target)
    }

    mutating func finishFailureReview() {
        guard case .reviewingFailure(let target) = phase else { return }
        phase = .pending(target)
    }

    @discardableResult
    mutating func confirm(_ target: Target, windowReady: Bool, isKeyboardDestination: Bool) -> Bool {
        guard pendingTarget == target, windowReady, isKeyboardDestination else { return false }
        phase = .entered(target)
        return true
    }

    mutating func cancel() {
        switch phase {
        case .entered, .cancelled: break
        default: phase = .cancelled
        }
    }
}

nonisolated enum WorkspacePane: String, CaseIterable, Identifiable, Sendable {
    case project, editor, timeline, tool
    var id: Self { self }
    var title: String {
        switch self {
        case .project: "Project Source"
        case .editor: "Editor"
        case .timeline: "Timeline"
        case .tool: "Tool Pane"
        }
    }
    var shortcut: String {
        switch self {
        case .project: "1"
        case .editor: "2"
        case .timeline: "3"
        case .tool: "4"
        }
    }
}

nonisolated struct WorkspaceFocusRequest: Equatable {
    var pane = WorkspacePane.project
    var revision = 0
}

nonisolated enum WorkspaceCommandAvailability {
    static func allows(isActive: Bool, isProjectWindowKey: Bool, hasSheet: Bool,
                       hasModalWindow: Bool, isClosing: Bool) -> Bool {
        isActive && isProjectWindowKey && !hasSheet && !hasModalWindow && !isClosing
    }
}

nonisolated enum PortraitEditorLayout {
    static let controlsWidth: CGFloat = 460
    static let minimumWidth: CGFloat = 700

    static func placesControlsBesideVideo(enabled: Bool, width: CGFloat) -> Bool {
        enabled && width.isFinite && width >= minimumWidth
    }
}

/// Workspace commands belong to the key project window, even before one of its
/// controls has received focus. Native window events and loading state drive updates.
@MainActor
final class WorkspaceCommandState: ObservableObject {
    static let shared = WorkspaceCommandState()
    @Published private(set) var controller: ProjectController?

    private struct Registration {
        weak var controller: ProjectController?
        var observations: Set<AnyCancellable>
    }
    private var registrations: [ObjectIdentifier: Registration] = [:]
    private var windowObservations = Set<AnyCancellable>()
    private let acceptsCommands: @MainActor (ProjectController) -> Bool
    private(set) var pendingRefresh: Task<Void, Never>?

    init(notifications: NotificationCenter = .default,
         acceptsCommands: @escaping @MainActor (ProjectController) -> Bool = { $0.acceptsWorkspaceCommands }) {
        self.acceptsCommands = acceptsCommands
        let events: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification,
            NSWindow.willCloseNotification,
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
        ]
        for event in events {
            notifications.publisher(for: event)
                .sink { [weak self] _ in
                    // AppKit window/application lifecycle notifications arrive on the main thread.
                    MainActor.assumeIsolated { self?.scheduleRefresh() }
                }
                .store(in: &windowObservations)
        }
    }

    func register(_ controller: ProjectController, windowChanges: AnyPublisher<Void, Never>) {
        var observations = Set<AnyCancellable>()
        let changes: [AnyPublisher<Void, Never>] = [
            controller.$isWorkspacePreparationPending.map { _ in () }.eraseToAnyPublisher(),
            controller.$isImporting.map { _ in () }.eraseToAnyPublisher(),
            controller.$isExporting.map { _ in () }.eraseToAnyPublisher(),
            controller.$isPresentingExportPanel.map { _ in () }.eraseToAnyPublisher(),
            controller.$applyingTransitionName.map { _ in () }.eraseToAnyPublisher(),
            controller.$toolPane.map { _ in () }.eraseToAnyPublisher(),
            windowChanges,
        ]
        Publishers.MergeMany(changes)
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &observations)
        registrations[ObjectIdentifier(controller)] = Registration(controller: controller, observations: observations)
        scheduleRefresh()
    }

    func unregister(_ controller: ProjectController) {
        registrations[ObjectIdentifier(controller)] = nil
        scheduleRefresh()
    }

    func recordShortcut(_ event: NSEvent) {
        #if DEBUG
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
              [UInt16(18), 19, 20, 21].contains(event.keyCode) else { return }
        TimelineFocusDiagnostics.record("workspace-shortcut keyCode=\(event.keyCode) deliveryAge=\(ProcessInfo.processInfo.systemUptime - event.timestamp)")
        recordAvailability("shortcut-arrival")
        #endif
    }

    private func recordAvailability(_ reason: String) {
        #if DEBUG
        TimelineFocusDiagnostics.record("workspace-state \(reason) registered=\(registrations.count) menuEnabled=\(controller != nil) refreshPending=\(pendingRefresh != nil)")
        for registration in registrations.values {
            guard let project = registration.controller else { continue }
            project.recordWorkspaceReadiness(reason)
        }
        #endif
    }

    // Called from the workspace's native appearance lifecycle, after preparation
    // and before its first frame. Do not leave initial command enablement queued
    // behind the newly presented workspace. Never call from updateNSView.
    func refreshForWorkspacePresentation() {
        registrations = registrations.filter { $0.value.controller != nil }
        let next = registrations.values.compactMap(\.controller).first(where: acceptsCommands)
        if controller !== next { controller = next }
        else { objectWillChange.send() }
        recordAvailability("refresh-completed")
    }

    private func scheduleRefresh() {
        recordAvailability("refresh-scheduled")
        guard pendingRefresh == nil else { return }
        pendingRefresh = Task { @MainActor [weak self] in
            // objectWillChange precedes the new value, and window attachment can
            // happen during a representable update. Read after those updates finish.
            await Task.yield()
            guard let self else { return }
            self.pendingRefresh = nil
            self.refreshForWorkspacePresentation()
        }
    }
}

struct WorkspaceCommands: Commands {
    @ObservedObject private var state = WorkspaceCommandState.shared
    @AppStorage(AppPreferenceKey.portraitVideo) private var portraitVideo = false

    var body: some Commands {
        // Auxiliary scenes are opened by their own workflows, not the Window menu.
        // Keep the separate native list of already-open document windows intact.
        CommandGroup(replacing: .singleWindowList) { }
        CommandGroup(before: .windowArrangement) {
            ForEach(WorkspacePane.allCases) { pane in
                Button(pane == .tool ? state.controller?.toolPane?.title ?? pane.title : pane.title) { state.controller?.requestWorkspaceFocus(pane) }
                    .keyboardShortcut(KeyEquivalent(Character(pane.shortcut)), modifiers: .command)
                    .disabled(state.controller == nil || (pane == .tool && state.controller?.toolPane == nil)
                        || (state.controller?.recordingSession != nil && (pane == .project || pane == .timeline)))
            }
            Toggle("Portrait Video", isOn: Binding(
                get: { portraitVideo },
                set: { value in
                    guard state.controller?.acceptsWorkspaceCommands == true,
                          value != portraitVideo else { return }
                    portraitVideo = value
                    var announcement = AttributedString(value ? "Portrait mode" : "Landscape mode")
                    announcement.accessibilitySpeechAnnouncementPriority = .high
                    AccessibilityNotification.Announcement(announcement).post()
                }
            ))
            .keyboardShortcut("l", modifiers: .command)
            .disabled(state.controller == nil)
            Divider()
        }
    }
}
