import SwiftUI

struct TransitionEditorView: View {
    @State private var draft: TimelineTransition
    @State private var durationText: String
    @State private var validationMessage: String?
    let update: (TimelineTransition) -> Void
    let delete: () -> Void
    let cancel: () -> Void

    init(
        transition: TimelineTransition,
        update: @escaping (TimelineTransition) -> Void,
        delete: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: transition)
        _durationText = State(initialValue: TransitionDurationInput.string(for: transition.duration))
        self.update = update
        self.delete = delete
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transition Editor")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            transitionPicker

            TransitionDurationField(text: $durationText)

            if let validationMessage {
                Text(validationMessage)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Delete Transition", role: .destructive, action: delete)
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                Button("Update Transition", action: applyUpdate)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 430)
    }

    @ViewBuilder
    private var transitionPicker: some View {
        switch draft.kind {
        case .video(let current):
            HStack(spacing: 8) {
                Text("Type").accessibilityHidden(true)
                Picker(selection: Binding(
                    get: { current },
                    set: { draft.kind = .video($0) }
                )) {
                    ForEach(videoTypes) { type in
                        Text(type.title).tag(type)
                    }
                } label: {
                    Text("Type")
                }
                .labelsHidden()
            }
        case .audio(let current):
            HStack(spacing: 8) {
                Text("Type").accessibilityHidden(true)
                Picker(selection: Binding(
                    get: { current },
                    set: { draft.kind = .audio($0) }
                )) {
                    ForEach(audioTypes) { type in
                        Text(type.title).tag(type)
                    }
                } label: {
                    Text("Type")
                }
                .labelsHidden()
            }
        }
    }

    private var videoTypes: [VideoTransitionType] {
        draft.edge == .between ? VideoTransitionType.allCases.filter { $0 != .fade } : [.fade]
    }

    private var audioTypes: [AudioTransitionType] {
        draft.edge == .between ? [.crossFade] : [.fade]
    }

    private func applyUpdate() {
        guard let duration = TransitionDurationInput.parse(durationText) else {
            validationMessage = "Enter a duration greater than zero, such as 1.0 or 1.25 seconds."
            return
        }
        draft.duration = duration
        update(draft)
    }
}
