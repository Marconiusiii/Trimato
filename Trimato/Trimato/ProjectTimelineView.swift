import AppKit
import SwiftUI

nonisolated enum TimelineAccessibility {
    static func clipsListLabel(trackName: String?) -> String {
        guard let trackName else { return "Timeline Clips" }
        return "Timeline Clips, \(trackName) track"
    }
}

nonisolated enum TimelineClipDeletionConfirmation {
    static let title = "Delete Clip?"

    static func message(clipName: String?) -> String {
        guard let clipName else {
            return "Remove this clip from the timeline? This can be undone."
        }
        return "Remove \(clipName) from the timeline? This can be undone."
    }
}

struct ProjectTimelineView: View {
    @ObservedObject var controller: ProjectController
    let openClipEditor: (EditorSelection) -> Void
    let workspacePaneLinks: Namespace.ID

    @AccessibilityFocusState private var focusedElement: TimelineElementSelection?
    @AccessibilityFocusState private var trackPickerFocused: Bool
    @AccessibilityFocusState private var timelineListFocused: Bool
    @State private var renamedClipName = ""
    @State private var isRenamingClip = false
    @State private var isRenamingTrack = false
    @State private var trackName = ""
    @State private var isAddingTrack = false
    @State private var editingTransition: TimelineTransition?
    @State private var transitionFocusReturn: TimelineElementSelection?
    @State private var clipPendingDeletion: TimelineClip?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Text("Timeline")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLinkedGroup(id: "workspace-panes", in: workspacePaneLinks)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(EditorTheme.controlSurface)
            Divider()
            HStack {
                Picker("Track", selection: activeTrackBinding) {
                    ForEach(controller.project.tracks) { track in
                        Text(track.name).tag(Optional(track.id))
                    }
                }
                .disabled(controller.project.tracks.isEmpty)
                .accessibilityFocused($trackPickerFocused)
                Menu("Track Actions") {
                    Button("Add Track…") { beginAddTrack() }
                    Button("Rename Track…") { beginRenameTrack() }
                        .disabled(controller.activeTimelineTrack == nil)
                    Menu("Append Imported Clip") {
                        ForEach(compatibleAssetsForActiveTrack) { asset in
                            Button(asset.name) { append(asset, to: controller.activeTimelineTrack) }
                        }
                    }
                    .disabled(compatibleAssetsForActiveTrack.isEmpty)
                    Divider()
                    Button("Move Track Up") { controller.moveActiveTrack(by: -1) }
                        .disabled(controller.activeTimelineTrack == nil)
                    Button("Move Track Down") { controller.moveActiveTrack(by: 1) }
                        .disabled(controller.activeTimelineTrack == nil)
                    Button("Delete Track", role: .destructive) { controller.deleteActiveTrack() }
                        .disabled(controller.activeTimelineTrack?.role != .additional)
                }
            }
            .padding(8)
            Divider()
            timelineContent
            Divider()
            HStack {
                Menu("Selected Element Actions") { selectedElementActions }
                    .disabled(!hasSelectedElement)
                    .keyboardShortcut(.return, modifiers: .control)
                Spacer()
            }
            .padding(8)
            .background(.bar)
        }
        .onAppear {
            reconcileActiveTrack()
        }
        .onChange(of: controller.project.tracks.map(\.id)) {
            reconcileActiveTrack()
        }
        .onChange(of: focusedElement) { element in
            guard let element else { return }
            controller.focusTimelineElement(element)
        }
        .onChange(of: controller.timelineFocusRestoreRequest) {
            guard let target = controller.timelineFocusRestoreTarget else { return }
            restoreTimelineElementFocus(to: target)
        }
        .onChange(of: controller.timelineTrackPickerFocusRestoreRequest) {
            restoreTrackPickerFocus()
        }
        .onChange(of: controller.timelineListFocusRestoreRequest) {
            restoreTimelineListFocus()
        }
        .sheet(isPresented: $isRenamingClip) { renameClipSheet }
        .sheet(isPresented: $isRenamingTrack) { renameTrackSheet }
        .sheet(isPresented: $isAddingTrack, onDismiss: restoreTrackPickerFocus) {
            AddTrackView(
                add: { kind, name in
                    controller.addTrack(kind: kind, name: name)
                    isAddingTrack = false
                },
                cancel: { isAddingTrack = false }
            )
        }
        .sheet(item: $editingTransition, onDismiss: restoreTimelineElementFocus) { transition in
            TransitionEditorView(
                transition: transition,
                contextDescription: transitionContextDescription(transition),
                update: { updated in
                    do {
                        try controller.updateTransition(updated)
                        editingTransition = nil
                    } catch { errorMessage = error.localizedDescription }
                },
                delete: {
                    transitionFocusReturn = fallbackFocusAfterDeleting(transition)
                    controller.deleteTransition(id: transition.id)
                    editingTransition = nil
                },
                cancel: { editingTransition = nil }
            )
        }
        .alert("Timeline Change Failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "The timeline could not be updated.")
        }
        .alert(TimelineClipDeletionConfirmation.title, isPresented: deleteClipConfirmationPresented) {
            Button("Cancel", role: .cancel) { cancelClipDeletion() }
            Button("Delete Clip", role: .destructive) { confirmClipDeletion() }
        } message: {
            Text(deleteClipConfirmationMessage)
        }
    }

    @ViewBuilder
    private var timelineContent: some View {
        if controller.project.tracks.isEmpty {
            emptyMessage("No clips in the project timeline")
        } else {
            accessibleTimelineElements
            .background(
                TimelineContextMenuKeyBridge(
                    focusedElement: focusedElement,
                    activate: activateTimelineElement,
                    renameClip: beginRenamingClip,
                    deleteClip: deleteTimelineClip,
                    editTransition: editTransition,
                    deleteTransition: deleteTimelineTransition,
                    copyClip: controller.copyTimelineClip,
                    pasteClipAfter: controller.pasteCopiedTimelineClip,
                    moveClipAfter: controller.moveCopiedTimelineClip
                )
                .frame(width: 0, height: 0)
            )
        }
    }

    @ViewBuilder
    private var accessibleTimelineElements: some View {
        if #available(macOS 26.0, *), let currentSelection {
            timelineScrollView
                .accessibilityDefaultFocus($focusedElement, currentSelection)
        } else {
            timelineScrollView
        }
    }

    private var timelineScrollView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
            if timelineElements.isEmpty {
                Text("No clips on this track")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            } else {
                ForEach(timelineElements) { element in
                    switch element.content {
                    case .clip(let clip):
                        clipButton(clip)
                    case .transition(let transition):
                        transitionButton(transition)
                    }
                }
            }
            }
            .padding(8)
        }
        .accessibilityLabel(timelineListAccessibilityLabel)
        .accessibilityIdentifier("trimato.timeline.clips")
        .accessibilityFocused($timelineListFocused)
    }

    private func emptyMessage(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }

    private var timelineElements: [TimelineListElement] {
        _ = controller.timelineContentRevision
        guard let track = controller.activeTimelineTrack else { return [] }
        return TimelineElementSequence.elements(
            track: track,
            transitions: TimelineElementSequence.transitions(
                for: track,
                in: controller.project
            )
        )
    }

    private var currentSelection: TimelineElementSelection? {
        controller.editorClip(at: controller.timelinePlayhead).map { .clip($0.id) }
    }

    private var activeTrackBinding: Binding<UUID?> {
        Binding(
            get: {
                controller.activeTimelineTrackID ??
                    ProjectController.preferredTimelineTrackID(in: controller.project)
            },
            set: { trackID in
                controller.activeTimelineTrackID = trackID
                restoreTrackPickerFocus()
            }
        )
    }

    private var timelineListAccessibilityLabel: String {
        TimelineAccessibility.clipsListLabel(trackName: controller.activeTimelineTrack?.name)
    }

    private func clipButton(_ clip: TimelineClip) -> some View {
        Button {
            controller.selection = .timelineClip(clip.id)
            openClipEditor(.timelineClip(clip.id))
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(clip.displayName).lineLimit(2)
                    Text(ProjectTimecodeFormatter.string(clip.duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if currentSelection == .clip(clip.id) {
                    Text("Current")
                        .font(.caption)
                        .foregroundStyle(EditorTheme.accent)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 56, alignment: .topLeading)
        .background(selectionBackground(.timelineClip(clip.id)), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(EditorTheme.separator))
        .accessibilityLabel(clip.displayName)
        .accessibilityValue(currentSelection == .clip(clip.id) ? "Current clip" : "")
        .accessibilityIdentifier(TimelineElementAccessibilityIdentifier.clip(clip.id))
        .accessibilityFocused($focusedElement, equals: .clip(clip.id))
        .contextMenu { clipActions(clip) }
    }

    private func transitionButton(_ transition: TimelineTransition) -> some View {
        Button {
            controller.selection = .transition(transition.id)
            beginEditingTransition(transition)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(transition.displayName).lineLimit(2)
                if let description = transitionContextDescription(transition) {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 56, alignment: .topLeading)
        .background(selectionBackground(.transition(transition.id)), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(EditorTheme.accent.opacity(0.75)))
        .accessibilityLabel(transition.displayName)
        .accessibilityIdentifier(TimelineElementAccessibilityIdentifier.transition(transition.id))
        .accessibilityFocused($focusedElement, equals: .transition(transition.id))
        .contextMenu {
            Button("Edit Transition…") { beginEditingTransition(transition) }
            Button("Delete Transition", role: .destructive) {
                deleteTimelineTransition(transition.id)
            }
        }
    }

    private func selectionBackground(_ selection: EditorSelection) -> Color {
        controller.selection == selection ? EditorTheme.accent.opacity(0.28) : EditorTheme.raisedSurface
    }

    private var hasSelectedElement: Bool {
        controller.selectedTimelineClip != nil || selectedTimelineTransition != nil
    }

    private var selectedTimelineTransition: TimelineTransition? {
        guard let selected = controller.selectedTransition,
              let track = controller.activeTimelineTrack else { return nil }
        return TimelineElementSequence.transitions(for: track, in: controller.project)
            .first { $0.id == selected.id }
    }

    @ViewBuilder
    private var selectedElementActions: some View {
        if let clip = controller.selectedTimelineClip {
            clipActions(clip)
        } else if let transition = selectedTimelineTransition {
            Button("Edit Transition…") { beginEditingTransition(transition) }
            Button("Delete Transition", role: .destructive) {
                deleteTimelineTransition(transition.id)
            }
        }
    }

    private func beginEditingTransition(_ transition: TimelineTransition) {
        transitionFocusReturn = .transition(transition.id)
        editingTransition = transition
    }

    private func transitionContextDescription(_ transition: TimelineTransition) -> String? {
        TimelineElementSequence.contextDescription(for: transition, in: controller.project)
    }

    private func fallbackFocusAfterDeleting(_ transition: TimelineTransition) -> TimelineElementSelection? {
        if let trailingID = transition.trailingClipID,
           controller.project.timelineClip(id: trailingID) != nil {
            return .clip(trailingID)
        }
        if let leadingID = transition.leadingClipID,
           controller.project.timelineClip(id: leadingID) != nil {
            return .clip(leadingID)
        }
        return nil
    }

    private func restoreTimelineElementFocus() {
        guard let target = transitionFocusReturn else { return }
        transitionFocusReturn = nil
        restoreTimelineElementFocus(to: target)
    }

    private func restoreTimelineElementFocus(to target: TimelineElementSelection) {
        focusedElement = nil
        trackPickerFocused = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            focusedElement = target
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            focusedElement = target
        }
    }

    private func activateTimelineElement(_ selection: TimelineElementSelection) {
        switch selection {
        case .clip(let id):
            controller.selection = .timelineClip(id)
            openClipEditor(.timelineClip(id))
        case .transition(let id):
            editTransition(id)
        }
    }

    private func editTransition(_ id: UUID) {
        guard let transition = controller.project.transition(id: id) else { return }
        controller.selection = .transition(id)
        beginEditingTransition(transition)
    }

    private func beginRenamingClip(_ id: UUID) {
        guard let clip = controller.project.timelineClip(id: id) else { return }
        controller.selection = .timelineClip(id)
        renamedClipName = clip.displayName
        isRenamingClip = true
    }

    private func deleteTimelineClip(_ id: UUID) {
        guard let clip = controller.project.timelineClip(id: id) else { return }
        controller.selection = .timelineClip(id)
        clipPendingDeletion = clip
    }

    private func deleteTimelineTransition(_ id: UUID) {
        guard let transition = controller.project.transition(id: id) else { return }
        let target = fallbackFocusAfterDeleting(transition)
        controller.deleteTransition(id: id)
        if let target {
            restoreTimelineElementFocus(to: target)
        }
    }

    @ViewBuilder
    private func clipActions(_ clip: TimelineClip) -> some View {
        Button("Open Clip Editor") { openClipEditor(.timelineClip(clip.id)) }
        Button("Rename Clip…") {
            controller.selection = .timelineClip(clip.id)
            renamedClipName = clip.displayName
            isRenamingClip = true
        }
        Divider()
        Button("Copy Clip") { controller.copyTimelineClip(id: clip.id) }
        Button("Paste Clip After") { controller.pasteCopiedTimelineClip(after: clip.id) }
        Button("Move Copied Clip After") { controller.moveCopiedTimelineClip(after: clip.id) }
        Divider()
        Button("Delete from Timeline", role: .destructive) {
            deleteTimelineClip(clip.id)
        }
    }

    private var deleteClipConfirmationPresented: Binding<Bool> {
        Binding(
            get: { clipPendingDeletion != nil },
            set: { presented in
                if !presented, clipPendingDeletion != nil {
                    cancelClipDeletion()
                }
            }
        )
    }

    private var deleteClipConfirmationMessage: String {
        TimelineClipDeletionConfirmation.message(clipName: clipPendingDeletion?.displayName)
    }

    private func cancelClipDeletion() {
        guard let clip = clipPendingDeletion else { return }
        clipPendingDeletion = nil
        restoreTimelineElementFocus(to: .clip(clip.id))
    }

    private func confirmClipDeletion() {
        guard let clip = clipPendingDeletion else { return }
        let focusTarget = fallbackFocusAfterDeletingClip(clip.id)
        clipPendingDeletion = nil
        controller.selection = .timelineClip(clip.id)
        controller.deleteSelection()
        if let focusTarget {
            restoreTimelineElementFocus(to: focusTarget)
        } else {
            restoreTimelineListFocus()
        }
    }

    private func fallbackFocusAfterDeletingClip(_ id: UUID) -> TimelineElementSelection? {
        TimelineElementSequence.focusTargetAfterDeletingClip(id, from: timelineElements)
    }

    private var renameClipSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Timeline Clip").font(.headline).accessibilityAddTraits(.isHeader)
            LabeledContent("Clip Name") {
                TextField("Clip Name", text: $renamedClipName)
                    .labelsHidden()
            }
            HStack {
                Button("Cancel", role: .cancel) { isRenamingClip = false }
                Button("Rename") {
                    do {
                        try controller.renameTimelineEntry(controller.selection, to: renamedClipName)
                        isRenamingClip = false
                    } catch { errorMessage = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var renameTrackSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Track").font(.headline).accessibilityAddTraits(.isHeader)
            LabeledContent("Track Name") {
                TextField("Track Name", text: $trackName)
                    .labelsHidden()
            }
            HStack {
                Button("Cancel", role: .cancel) { isRenamingTrack = false }
                Button("Rename") {
                    do {
                        try controller.renameActiveTrack(to: trackName)
                        isRenamingTrack = false
                    } catch { errorMessage = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func reconcileActiveTrack() {
        if let id = controller.activeTimelineTrackID,
           controller.project.tracks.contains(where: { $0.id == id }) { return }
        controller.activeTimelineTrackID = ProjectController.preferredTimelineTrackID(in: controller.project)
    }

    private func beginRenameTrack() {
        guard let track = controller.activeTimelineTrack else { return }
        trackName = track.name
        isRenamingTrack = true
    }

    private func beginAddTrack() {
        isAddingTrack = true
    }

    private var compatibleAssetsForActiveTrack: [MediaAssetRecord] {
        guard let track = controller.activeTimelineTrack else { return [] }
        return controller.project.media.filter { asset in
            (track.kind == .video && asset.hasVideo) || (track.kind == .audio && asset.hasAudio)
        }
    }

    private func append(_ asset: MediaAssetRecord, to track: TimelineTrack?) {
        guard let track,
              let clipID = controller.place(.append, editing: .asset(asset.id), segments: asset.sourceEdit, onTrack: track.id) else {
            return
        }
        controller.requestTimelineFocusRestore(to: .clip(clipID))
    }

    private func restoreTrackPickerFocus() {
        focusedElement = nil
        timelineListFocused = false
        trackPickerFocused = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            trackPickerFocused = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            trackPickerFocused = true
        }
    }

    private func restoreTimelineListFocus() {
        focusedElement = nil
        trackPickerFocused = false
        timelineListFocused = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            timelineListFocused = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            timelineListFocused = true
        }
    }
}

private struct AddTrackView: View {
    let add: (TimelineTrackKind, String) -> Void
    let cancel: () -> Void

    @State private var trackName = ""
    @State private var trackKind = TimelineTrackKind.audio
    @AccessibilityFocusState private var trackTypeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Track")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Form {
                Picker("Track Type", selection: trackKindBinding) {
                    ForEach(TimelineTrackKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .accessibilityFocused($trackTypeFocused)
                TextField("Track Name", text: $trackName)
            }
            .formStyle(.grouped)
            .frame(height: 130)
            HStack {
                Button("Cancel", role: .cancel, action: cancel)
                Button("Add Track") { add(trackKind, trackName) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var trackKindBinding: Binding<TimelineTrackKind> {
        Binding(
            get: { trackKind },
            set: { value in
                trackKind = value
                restoreTrackTypeFocus()
            }
        )
    }

    private func restoreTrackTypeFocus() {
        trackTypeFocused = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            trackTypeFocused = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            trackTypeFocused = true
        }
    }
}

struct TimelineListElement: Identifiable, Equatable {
    enum Content {
        case clip(TimelineClip)
        case transition(TimelineTransition)
    }

    let content: Content

    var id: String {
        switch content {
        case .clip(let clip): "clip-\(clip.id.uuidString)"
        case .transition(let transition): "transition-\(transition.id.uuidString)"
        }
    }
}

extension TimelineListElement.Content: Equatable {}

enum TimelineElementSequence {
    static func focusTargetAfterDeletingClip(
        _ clipID: UUID,
        from elements: [TimelineListElement]
    ) -> TimelineElementSelection? {
        guard let index = elements.firstIndex(where: {
            if case .clip(let clip) = $0.content { return clip.id == clipID }
            return false
        }) else { return nil }
        let remaining = elements.enumerated().compactMap { offset, element -> TimelineListElement? in
            guard offset != index else { return nil }
            if case .transition(let transition) = element.content,
               transition.leadingClipID == clipID || transition.trailingClipID == clipID {
                return nil
            }
            return element
        }
        guard !remaining.isEmpty else { return nil }
        let targetIndex = min(index, remaining.count - 1)
        switch remaining[targetIndex].content {
        case .clip(let clip): return .clip(clip.id)
        case .transition(let transition): return .transition(transition.id)
        }
    }

    static func transitions(
        for track: TimelineTrack,
        in project: TrimatoProject
    ) -> [TimelineTransition] {
        let clipIDs = Set(track.clips.map(\.id))
        return project.transitions.compactMap { transition in
            let referencedIDs = [transition.leadingClipID, transition.trailingClipID].compactMap { $0 }
            if !referencedIDs.isEmpty, referencedIDs.allSatisfy(clipIDs.contains) {
                var resolved = transition
                resolved.trackID = track.id
                return resolved
            }
            if referencedIDs.contains(where: { project.timelineClip(id: $0) != nil }) {
                return nil
            }
            return transition.trackID == track.id ? transition : nil
        }
    }

    static func contextDescription(
        for transition: TimelineTransition,
        in project: TrimatoProject
    ) -> String? {
        guard transition.edge == .between,
              let leadingID = transition.leadingClipID,
              let trailingID = transition.trailingClipID,
              let leading = project.timelineClip(id: leadingID),
              let trailing = project.timelineClip(id: trailingID) else { return nil }
        return "\(leading.displayName) to \(trailing.displayName)"
    }

    static func elements(
        track: TimelineTrack,
        transitions: [TimelineTransition]
    ) -> [TimelineListElement] {
        let orderedTransitions = transitions.sorted { $0.id.uuidString < $1.id.uuidString }
        var includedTransitionIDs: Set<UUID> = []
        var result: [TimelineListElement] = []

        for clip in track.sortedClips {
            for transition in orderedTransitions where
                transition.trailingClipID == clip.id &&
                (transition.edge == .intro || transition.edge == .between) {
                result.append(TimelineListElement(content: .transition(transition)))
                includedTransitionIDs.insert(transition.id)
            }

            result.append(TimelineListElement(content: .clip(clip)))

            for transition in orderedTransitions where
                transition.leadingClipID == clip.id && transition.edge == .outro {
                result.append(TimelineListElement(content: .transition(transition)))
                includedTransitionIDs.insert(transition.id)
            }
        }

        for transition in orderedTransitions where !includedTransitionIDs.contains(transition.id) {
            result.append(TimelineListElement(content: .transition(transition)))
        }
        return result
    }
}

enum ProjectTimecodeFormatter {
    static func string(_ time: ProjectTime) -> String {
        let milliseconds = max(Int((time.seconds * 1_000).rounded()), 0)
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let seconds = (milliseconds / 1_000) % 60
        let remainder = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, remainder)
    }
}
