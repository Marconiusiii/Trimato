import SwiftUI

struct TransitionEditorView: View {
    @State private var draft: TimelineTransition
    @State private var transitionName: String
    @State private var durationText: String
    @State private var validationMessage: String?
    private struct QuitDraft: Equatable {
        let transition: TimelineTransition
        let name: String
        let duration: String
    }
    private let original: TimelineTransition
    let contextDescription: String?
    let update: (TimelineTransition) -> Void
    let delete: () -> Void
    let cancel: () -> Void

    init(
        transition: TimelineTransition,
        contextDescription: String? = nil,
        update: @escaping (TimelineTransition) -> Void,
        delete: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) {
        original = transition
        _draft = State(initialValue: transition)
        _transitionName = State(initialValue: transition.displayName)
        _durationText = State(initialValue: TransitionDurationInput.string(for: transition.duration))
        self.contextDescription = contextDescription
        self.update = update
        self.delete = delete
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transition Editor")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if let contextDescription {
                Text(contextDescription)
            }

            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Transition Name") {
                    TextField("Transition name", text: $transitionName)
                        .labelsHidden()
                }
                transitionPicker
                TransitionDurationField(text: $durationText, label: durationLabel)
            }

            Button("Delete Transition", role: .destructive, action: delete)

            if let validationMessage {
                Text(validationMessage)
                    .foregroundStyle(.red)
            }

            NativeModalActions(
                primaryTitle: "Update Transition",
                cancel: cancel,
                primary: applyUpdate
            )
        }
        .padding(20)
        .frame(width: 430)
        .pendingQuitDraft(QuitDraft(transition: draft, name: transitionName, duration: durationText),
            pending: draft != original || transitionName != original.displayName || durationText != TransitionDurationInput.string(for: original.duration),
            validate: { _ = try quitTransition() }, apply: {
                guard let controller = ExternalMediaOpenCoordinator.shared.activeProjectController else {
                    throw QuitDraftError(message: "The transition project is no longer open.")
                }
                try controller.updateTransition(quitTransition())
            })
    }

    @ViewBuilder
    private var transitionPicker: some View {
        switch draft.kind {
        case .video(let current):
            Picker("Transition Type", selection: Binding(
                get: { current },
                set: { newValue in
                    let followsDefaultName = draft.normalizedCustomName == nil && transitionName == draft.defaultDisplayName
                    draft.kind = .video(newValue)
                    if followsDefaultName { transitionName = draft.defaultDisplayName }
                }
            )) {
                ForEach(videoTypes) { type in
                    Text(type.title).tag(type)
                }
            }
        case .audio(let current):
            Picker("Transition Type", selection: Binding(
                get: { current },
                set: { newValue in
                    let followsDefaultName = draft.normalizedCustomName == nil && transitionName == draft.defaultDisplayName
                    draft.kind = .audio(newValue)
                    if followsDefaultName { transitionName = draft.defaultDisplayName }
                }
            )) {
                ForEach(audioTypes) { type in
                    Text(type.title).tag(type)
                }
            }
        }
    }

    private var durationLabel: String {
        draft.kind == .video(.fade) || draft.kind == .audio(.fade)
            ? FadeTransitionLabels.duration(edge: draft.edge) : TransitionDurationInput.accessibilityLabel
    }

    private var videoTypes: [VideoTransitionType] {
        draft.edge == .between ? VideoTransitionType.allCases.filter { $0 != .fade } : [.fade]
    }

    private var audioTypes: [AudioTransitionType] {
        draft.edge == .between ? [.crossFade, .fadeOutIn] : [.fade]
    }

    private func quitTransition() throws -> TimelineTransition {
        guard let duration = TransitionDurationInput.parse(durationText) else {
            throw QuitDraftError(message: "Enter a transition duration greater than zero.")
        }
        let name = transitionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw QuitDraftError(message: "Enter a name for the transition.") }
        var result = draft
        result.duration = duration
        result.customName = name == result.defaultDisplayName ? nil : name
        return result
    }

    private func applyUpdate() {
        guard let duration = TransitionDurationInput.parse(durationText) else {
            validationMessage = "Enter a duration greater than zero, such as 1.0 or 1.25 seconds."
            return
        }
        draft.duration = duration
        let trimmedName = transitionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationMessage = "Enter a name for the transition."
            return
        }
        draft.customName = trimmedName == draft.defaultDisplayName ? nil : trimmedName
        update(draft)
    }
}
