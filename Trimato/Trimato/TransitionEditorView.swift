import SwiftUI

struct TransitionEditorView: View {
    @State private var draft: TimelineTransition
    @State private var transitionName: String
    @State private var durationText: String
    @State private var validationMessage: String?
    @State private var pickerFocusTask: Task<Void, Never>?
    @AccessibilityFocusState private var typePickerFocused: Bool
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
                TransitionDurationField(text: $durationText)
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
        .onDisappear {
            pickerFocusTask?.cancel()
        }
        .alert("Transition Could Not Be Updated", isPresented: Binding(
            get: { validationMessage != nil },
            set: { if !$0 { validationMessage = nil } }
        )) {
            Button("OK") { validationMessage = nil }
        } message: {
            Text(validationMessage ?? "The transition could not be updated.")
        }
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
                    restoreTypePickerFocus()
                }
            )) {
                ForEach(videoTypes) { type in
                    Text(type.title).tag(type)
                }
            }
            .accessibilityFocused($typePickerFocused)
        case .audio(let current):
            Picker("Transition Type", selection: Binding(
                get: { current },
                set: { newValue in
                    let followsDefaultName = draft.normalizedCustomName == nil && transitionName == draft.defaultDisplayName
                    draft.kind = .audio(newValue)
                    if followsDefaultName { transitionName = draft.defaultDisplayName }
                    restoreTypePickerFocus()
                }
            )) {
                ForEach(audioTypes) { type in
                    Text(type.title).tag(type)
                }
            }
            .accessibilityFocused($typePickerFocused)
        }
    }

    private func restoreTypePickerFocus() {
        pickerFocusTask?.cancel()
        typePickerFocused = false
        pickerFocusTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            typePickerFocused = true
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            typePickerFocused = true
        }
    }

    private var videoTypes: [VideoTransitionType] {
        draft.edge == .between ? VideoTransitionType.allCases.filter { $0 != .fade } : [.fade]
    }

    private var audioTypes: [AudioTransitionType] {
        draft.edge == .between ? [.crossFade, .fadeOutIn] : [.fade]
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
