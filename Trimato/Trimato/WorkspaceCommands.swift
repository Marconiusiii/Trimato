import AppKit
import SwiftUI

nonisolated enum WorkspacePane: String, CaseIterable, Identifiable, Sendable {
    case project, editor, timeline
    var id: Self { self }
    var title: String { "Focus " + rawValue.capitalized }
    var shortcut: String {
        switch self {
        case .project: "1"
        case .editor: "2"
        case .timeline: "3"
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

nonisolated enum WorkspacePaneNavigation {
    static func timelineTarget(remembered: TimelineElementSelection?, keyboard: TimelineElementSelection?,
                               available: [TimelineElementSelection]) -> TimelineElementSelection? {
        [remembered, keyboard].compactMap { $0 }.first { available.contains($0) }
    }
}

nonisolated enum PortraitEditorLayout {
    static let controlsWidth: CGFloat = 460
    static let minimumWidth: CGFloat = 700

    static func placesControlsBesideVideo(enabled: Bool, width: CGFloat) -> Bool {
        enabled && width.isFinite && width >= minimumWidth
    }
}

struct WorkspaceCommands: Commands {
    @FocusedObject private var controller: ProjectController?
    @AppStorage(AppPreferenceKey.portraitVideo) private var portraitVideo = false

    var body: some Commands {
        CommandGroup(before: .windowArrangement) {
            ForEach(WorkspacePane.allCases) { pane in
                Button(pane.title) { controller?.requestWorkspaceFocus(pane) }
                    .keyboardShortcut(KeyEquivalent(Character(pane.shortcut)), modifiers: .command)
                    .disabled(controller?.acceptsWorkspaceCommands != true)
            }
            Divider()
            Toggle("Portrait Video", isOn: Binding(
                get: { portraitVideo },
                set: { value in
                    guard controller?.acceptsWorkspaceCommands == true else { return }
                    portraitVideo = value
                }
            ))
            .disabled(controller?.acceptsWorkspaceCommands != true)
            Divider()
        }
    }
}
