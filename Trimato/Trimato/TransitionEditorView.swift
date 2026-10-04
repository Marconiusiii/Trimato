import SwiftUI

struct TransitionEditorView: View {
    @State private var draft: TimelineTransition
    @State private var transitionName: String
    @State private var durationText: String
    @State private var includeAudio: Bool
    @State private var linkedAudioType: AudioTransitionType
    @State private var linkedAudioCurve: AudioCrossFadeCurve
    private struct QuitDraft: Equatable {
        let transition: TimelineTransition
        let name: String
        let duration: String
        let includeAudio: Bool
        let audioType: AudioTransitionType
        let audioCurve: AudioCrossFadeCurve
    }
    private let original: TimelineTransition
    let contextDescription: String?
    @ObservedObject var session: TransitionToolSession
    let focusRevision: Int
    @Environment(\.controlActiveState) private var windowActivity
    @State private var appliedFocusRevision: Int?
    @FocusState private var nameFocused: Bool
    @FocusState private var typeFocused: Bool
    let cancel: () -> Void

    init(
        transition: TimelineTransition,
        contextDescription: String? = nil,
        session: TransitionToolSession,
        focusRevision: Int,
        cancel: @escaping () -> Void
    ) {
        let linked = session.project.linkedTransition(to: transition)
        let linkedType: AudioTransitionType
        if case .audio(let type) = linked?.kind { linkedType = type } else { linkedType = .crossFade }
        _includeAudio = State(initialValue: linked != nil)
        _linkedAudioType = State(initialValue: linkedType)
        _linkedAudioCurve = State(initialValue: linked?.effectiveAudioCurve ?? .linear)
        original = transition
        _draft = State(initialValue: transition)
        _transitionName = State(initialValue: transition.displayName)
        _durationText = State(initialValue: TransitionDurationInput.string(for: transition.duration))
        self.contextDescription = contextDescription
        self.session = session
        self.focusRevision = focusRevision
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transition Editor")
                .editorFont(.title2, weight: .semibold)
                .accessibilityAddTraits(.isHeader)

            if let contextDescription {
                Text(contextDescription)
            }

            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Transition Name") {
                    TextField("Transition name", text: $transitionName, prompt: Text(""))
                        .labelsHidden()
                        .focused($nameFocused)
                }
                transitionPicker
                if managesLinkedAudio, linkedEdit != nil {
                    Toggle("Include Audio Transition", isOn: $includeAudio)
                    if includeAudio {
                        AudioTransitionOptions(selection: $linkedAudioType, curve: $linkedAudioCurve,
                            linked: true, focused: $typeFocused)
                    }
                }
                TransitionDurationField(text: $durationText, label: durationLabel)
            }

            Button("Delete Transition", role: .destructive, action: session.delete)

            Spacer(minLength: 0)

            NativeModalActions(helpTopic: .transitions,
                primaryTitle: "Update Transition",
                cancel: cancel,
                primary: applyUpdate
            )
        }
        .padding(EditorTheme.dialogPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: quitDraft, initial: true) { _, _ in session.hasPendingEdits = hasPendingEdits }
        .task(id: windowActivity == .key ? focusRevision : nil) {
            guard windowActivity == .key, appliedFocusRevision != focusRevision else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            appliedFocusRevision = focusRevision
            nameFocused = true
        }
        .pendingQuitDraft(quitDraft, pending: hasPendingEdits,
            validate: { _ = try quitTransition(); _ = try session.validateProject() },
            apply: { try session.updateForQuit(quitTransition(), linkedAudio: quitLinkedAudio(),
                managesLinkedAudio: managesLinkedAudio) })
    }

    private var quitDraft: QuitDraft { QuitDraft(transition: draft, name: transitionName, duration: durationText,
        includeAudio: includeAudio, audioType: linkedAudioType, audioCurve: linkedAudioCurve) }
    private var hasPendingEdits: Bool {
        draft != original || transitionName != original.displayName
            || durationText != TransitionDurationInput.string(for: original.duration)
            || (managesLinkedAudio && (includeAudio != (originalLinkedAudio != nil)
                || linkedAudioType != originalLinkedAudioType
                || linkedAudioCurve != (originalLinkedAudio?.effectiveAudioCurve ?? .linear)))
    }

    private var originalLinkedAudio: TimelineTransition? { session.project.linkedTransition(to: original) }
    private var originalLinkedAudioType: AudioTransitionType {
        if case .audio(let type) = originalLinkedAudio?.kind { return type }
        return .crossFade
    }
    private var managesLinkedAudio: Bool {
        if case .video = draft.kind { return draft.edge == .between }
        return false
    }
    private var linkedEdit: TransitionEdit? {
        guard let leading = draft.leadingClipID, let trailing = draft.trailingClipID else { return nil }
        let edit = TransitionEdit(leadingClipID: leading, trailingClipID: trailing)
        return edit.linkedAudioEdit(in: session.project) != nil ? edit : nil
    }
    private func setKind(_ kind: TimelineTransitionKind) {
        let followsDefaultName = draft.normalizedCustomName == nil && transitionName == draft.defaultDisplayName
        draft.kind = kind
        if followsDefaultName { transitionName = draft.defaultDisplayName }
    }
    @ViewBuilder
    private var transitionPicker: some View {
        switch draft.kind {
        case .video(let current):
            if draft.edge == .between {
                VideoTransitionOptions(selection: Binding(get: { current }, set: { setKind(.video($0)) }),
                    focused: $typeFocused)
            } else {
                Picker("Transition Type", selection: Binding(get: { current }, set: { setKind(.video($0)) })) {
                    Text("Fade").tag(VideoTransitionType.fade)
                }
            }
        case .audio(let current):
            if draft.edge == .between {
                AudioTransitionOptions(selection: Binding(get: { current }, set: { setKind(.audio($0)) }),
                    curve: Binding(get: { draft.effectiveAudioCurve }, set: { draft.audioCurve = $0 }),
                    linked: false, focused: $typeFocused)
            } else {
                Picker("Transition Type", selection: Binding(get: { current }, set: { setKind(.audio($0)) })) {
                    Text("Fade").tag(AudioTransitionType.fade)
                }
            }
        }
    }

    private func quitLinkedAudio() throws -> TimelineTransition? {
        guard managesLinkedAudio, includeAudio, let edit = linkedEdit else { return nil }
        let transition = try quitTransition()
        return edit.makeTransitions(trackID: transition.trackID, kind: transition.kind,
            duration: transition.duration, includeAudio: true, audioType: linkedAudioType,
            audioCurve: linkedAudioCurve, in: session.project).last
    }

    private var durationLabel: String {
        draft.kind == .video(.fade) || draft.kind == .audio(.fade)
            ? FadeTransitionLabels.duration(edge: draft.edge) : TransitionDurationInput.accessibilityLabel
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
        do { session.update(try quitTransition(), linkedAudio: try quitLinkedAudio(), managesLinkedAudio: managesLinkedAudio) }
        catch { session.presentError(error.localizedDescription) }
    }
}
