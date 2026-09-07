import AppKit
import Combine
import SwiftUI

/// Editor drafts are applied before their containing clip, and before saving the document.
@MainActor
final class ProjectQuitEdits {
    struct Entry {
        let priority: Int
        let hasChanges: () -> Bool
        let validate: () throws -> Void
        let apply: () async throws -> Void
    }
    private var entries: [UUID: Entry] = [:]
    func register(_ id: UUID, entry: Entry) { entries[id] = entry }
    func remove(_ id: UUID) { entries[id] = nil }
    var hasChanges: Bool { entries.values.contains { $0.hasChanges() } }

    func apply() async throws {
        let ordered = entries.sorted { $0.value.priority < $1.value.priority }
        // Validate every draft before changing the project.
        for (_, entry) in ordered where entry.hasChanges() { try entry.validate() }
        for (id, entry) in ordered where entry.hasChanges() {
            try entry.validate()
            try await entry.apply()
            // A successful draft must not be applied twice if the save panel is cancelled.
            if entry.priority < 100 { entries[id] = nil }
        }
    }
}

struct QuitDraftError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct QuitDraftModifier<Value: Equatable>: ViewModifier {
    let value: Value
    let pending: Bool
    let validate: () throws -> Void
    let apply: () async throws -> Void
    @ObservedObject private var review = QuitReviewState.shared
    @State private var id = UUID()
    @State private var owner: ProjectQuitEdits?

    func body(content: Content) -> some View {
        content
            .disabled(review.coordinator != nil)
            .onChange(of: value, initial: true) { _, _ in register() }
            .onChange(of: pending) { _, _ in register() }
            .onDisappear { owner?.remove(id) }
    }

    private func register() {
        let edits = owner ?? ExternalMediaOpenCoordinator.shared.activeProjectController?.quitEdits
        owner = edits
        edits?.register(id, entry: .init(priority: 0, hasChanges: { pending }, validate: validate, apply: apply))
    }
}

extension View {
    func pendingQuitDraft<Value: Equatable>(_ value: Value, pending: Bool = true,
                                            validate: @escaping () throws -> Void = {},
                                            apply: @escaping () async throws -> Void) -> some View {
        modifier(QuitDraftModifier(value: value, pending: pending, validate: validate, apply: apply))
    }
}

@MainActor
final class QuitReviewState: ObservableObject {
    static let shared = QuitReviewState()
    @Published var coordinator: ProjectWindowSaveCoordinator?
}

struct QuitReviewWindow: View {
    @ObservedObject private var state = QuitReviewState.shared
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let coordinator = state.coordinator {
                QuitReviewContent(coordinator: coordinator)
            }
        }
        .onChange(of: state.coordinator == nil) { _, empty in
            if empty { dismissWindow(id: "quit-review") }
        }
        .onDisappear {
            guard let coordinator = state.coordinator else { return }
            coordinator.cancelQuitReview()
        }
    }
}

private struct QuitReviewContent: View {
    @ObservedObject var coordinator: ProjectWindowSaveCoordinator
    var body: some View {
        ProjectCloseConfirmation(coordinator: coordinator)
            .disabled(coordinator.isResolvingClose)
            .onChange(of: coordinator.isConfirmingClose) { _, showing in
                if !showing { coordinator.closeConfirmationDismissed() }
            }
    }
}

private struct QuitInteractionBlocker: ViewModifier {
    @ObservedObject private var review = QuitReviewState.shared
    func body(content: Content) -> some View { content.disabled(review.coordinator != nil) }
}

extension View {
    func blocksEditingDuringQuit() -> some View { modifier(QuitInteractionBlocker()) }
}
