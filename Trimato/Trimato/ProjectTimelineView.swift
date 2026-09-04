import AppKit
import SwiftUI

nonisolated enum TimelineAccessibility {
    static func clipValue(isCurrent: Bool, isSelected: Bool) -> String {
        var values: [String] = []
        if isCurrent { values.append("Current clip") }
        if isSelected {
            values.append("Selected")
        }
        return values.joined(separator: ", ")
    }

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

    @State private var keyboardFocusedElement: TimelineElementSelection?
    @State private var focusedElement: TimelineElementSelection?
    @State private var renamedClipName = ""
    @State private var isRenamingClip = false
    @State private var isRenamingTrack = false
    @State private var trackName = ""
    @State private var isAddingTrack = false
    @State private var editingTransition: TimelineTransition?
    @State private var transitionFocusReturn: TimelineElementSelection?
    @State private var transitionPendingDeletion: TimelineTransition?
    @State private var clipPendingDeletion: TimelineClip?
    @State private var errorMessage: String?
    @State private var errorTitle = "Timeline Change Failed"

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
                    ForEach(controller.project.orderedTimelineTracks) { track in
                        Text(track.name).tag(Optional(track.id))
                    }
                }
                .disabled(controller.project.tracks.isEmpty)
                if controller.activeTimelineTrack?.kind == .audio {
                    Toggle("Mute Track", isOn: Binding(
                        get: { controller.activeTimelineTrack?.isMuted ?? false },
                        set: { controller.setActiveTrackMuted($0) }
                    ))
                    .toggleStyle(.checkbox)
                }
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
                        .disabled(!canMoveActiveTrack(by: -1))
                    Button("Move Track Down") { controller.moveActiveTrack(by: 1) }
                        .disabled(!canMoveActiveTrack(by: 1))
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
        .accessibilityIdentifier("trimato.timeline.root")
        .background(TimelineKeyboardBridge(
            accessibilitySelection: focusedElement,
            keyboardSelection: keyboardFocusedElement,
            movingClipID: controller.movingTimelineClipID,
            allowsNudging: { element in
                guard case .clip(let id) = element else { return false }
                return controller.canNudgeTimelineClip(id: id)
            },
            perform: performTimelineKey
        ))
        .onChange(of: keyboardFocusedElement) { _, element in
            controller.timelineHasKeyboardFocus = element != nil
            if !NSWorkspace.shared.isVoiceOverEnabled, let element { controller.focusTimelineElement(element) }
        }
        .onAppear {
            reconcileActiveTrack()
        }
        .onChange(of: controller.project.tracks.map(\.id)) {
            reconcileActiveTrack()
        }
        .onChange(of: focusedElement) { _, element in
            guard let element else { return }
            controller.focusTimelineElement(element)
        }
        .sheet(isPresented: $isRenamingClip) { renameClipSheet }
        .sheet(isPresented: $isRenamingTrack) { renameTrackSheet }
        .sheet(isPresented: $isAddingTrack) {
            AddTrackView(
                add: { kind, name in
                    controller.addTrack(kind: kind, name: name)
                    isAddingTrack = false
                },
                cancel: { isAddingTrack = false }
            )
        }
        .sheet(item: $editingTransition, onDismiss: finishTransitionEditing) { transition in
            TransitionEditorView(
                transition: transition,
                contextDescription: transitionContextDescription(transition),
                update: { updated in
                    do {
                        try controller.updateTransition(updated)
                        editingTransition = nil
                    } catch { presentTimelineError(error) }
                },
                delete: {
                    transitionFocusReturn = fallbackFocusAfterDeleting(transition)
                    transitionPendingDeletion = transition
                    editingTransition = nil
                },
                cancel: { editingTransition = nil }
            )
        }
        .alert(errorTitle, isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "The timeline could not be updated.")
        }
        .background(TimelineClipDeletionAlertBridge(clip: clipPendingDeletion, completed: finishClipDeletion))
    }

    @ViewBuilder
    private var timelineContent: some View {
        if controller.project.tracks.isEmpty {
            emptyMessage("No clips in the project timeline")
        } else {
            timelineScrollView
                .onDeleteCommand(perform: deleteFocusedTimelineElement)
        }
    }

    private func deleteFocusedTimelineElement() {
        switch focusedElement {
        case .clip(let id):
            deleteTimelineClip(id)
        case .transition(let id):
            deleteTimelineTransition(id)
        case nil:
            break
        }
    }

    private var timelineScrollView: some View {
        TimelineClipsCollection(
            items: timelineCollectionItems,
            accessibilityLabel: timelineListAccessibilityLabel,
            focusRequest: controller.timelineFocusRestoreRequest,
            focusTarget: controller.timelineFocusRestoreTarget,
            listFocusRequest: controller.timelineListFocusRestoreRequest,
            movingClipID: controller.movingTimelineClipID,
            actions: TimelineCollectionActions(
                activate: activateTimelineElement,
                focus: focusNativeTimelineElement,
                renameClip: beginRenamingClip,
                copyClip: controller.copyTimelineClip,
                pasteClipAfter: controller.pasteCopiedTimelineClip,
                toggleClipMovement: controller.toggleClipMovement,
                moveClip: { destination, id in controller.moveClip(to: destination, targetID: id) },
                canMoveClip: { destination, id in controller.canMoveClip(to: destination, targetID: id) },
                delete: deleteTimelineElement
            )
        )
        .frame(minHeight: 88)
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

    private var currentClipID: UUID? {
        controller.currentTimelineClip(at: controller.timelinePlayhead)?.id
    }

    private var activeTrackBinding: Binding<UUID?> {
        Binding(
            get: {
                controller.activeTimelineTrackID ??
                    ProjectController.preferredTimelineTrackID(in: controller.project)
            },
            set: { trackID in
                controller.activeTimelineTrackID = trackID
            }
        )
    }

    private var timelineListAccessibilityLabel: String {
        TimelineAccessibility.clipsListLabel(trackName: controller.activeTimelineTrack?.name)
    }

    private var timelineCollectionItems: [TimelineCollectionItemModel] {
        timelineElements.map { element in
            switch element.content {
            case .clip(let clip):
                return TimelineCollectionItemModel(
                    selection: .clip(clip.id),
                    title: clip.displayName,
                    subtitle: nil,
                    accessibilityValue: clipAccessibilityValue(clip),
                    accessibilityHint: "Enter opens Clip Editor. Space toggles selection for moving.",
                    isSelected: controller.movingTimelineClipID == clip.id || controller.selection == .timelineClip(clip.id),
                    isTransition: false
                )
            case .transition(let transition):
                return TimelineCollectionItemModel(
                    selection: .transition(transition.id),
                    title: transition.displayName,
                    subtitle: transitionContextDescription(transition),
                    accessibilityValue: "",
                    accessibilityHint: "Enter opens the transition editor.",
                    isSelected: controller.selection == .transition(transition.id),
                    isTransition: true
                )
            }
        }
    }

    private func focusNativeTimelineElement(_ selection: TimelineElementSelection) {
        focusedElement = selection
        keyboardFocusedElement = selection
    }

    private func deleteTimelineElement(_ selection: TimelineElementSelection) {
        switch selection {
        case .clip(let id): deleteTimelineClip(id)
        case .transition(let id): deleteTimelineTransition(id)
        }
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

    private func trimTimelineClipEnd(_ id: UUID) {
        do {
            try controller.trimTimelineClipEnd(id: id)
            restoreTimelineElementFocus(to: .clip(id))
        } catch {
            errorTitle = "Clip Could Not Be Trimmed"
            errorMessage = error.localizedDescription
        }
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

    private func editorSelection(for element: TimelineElementSelection?) -> EditorSelection? {
        switch element {
        case .clip(let id): .timelineClip(id)
        case .transition(let id): .transition(id)
        case nil: nil
        }
    }

    private func restoreTimelineElementFocus() {
        guard let target = transitionFocusReturn else { return }
        transitionFocusReturn = nil
        restoreTimelineElementFocus(to: target)
    }

    private func finishTransitionEditing() {
        guard let transition = transitionPendingDeletion else {
            restoreTimelineElementFocus()
            return
        }
        transitionPendingDeletion = nil
        let target = transitionFocusReturn
        transitionFocusReturn = nil
        deleteAfterFocusing(target, in: NSApp.keyWindow) {
            controller.deleteTransition(
                id: transition.id,
                selecting: editorSelection(for: target) ?? .project
            )
        }
    }

    private func restoreTimelineElementFocus(to target: TimelineElementSelection) {
        controller.requestTimelineFocusRestore(to: target)
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
        // Clear the prior request while the native confirmation takes focus.
        // Cancellation can then request the same row once after dismissal.
        focusedElement = nil
        keyboardFocusedElement = nil
        clipPendingDeletion = clip
    }

    private func deleteTimelineTransition(_ id: UUID) {
        guard let transition = controller.project.transition(id: id) else { return }
        let target = fallbackFocusAfterDeleting(transition)
        deleteAfterFocusing(target, in: NSApp.keyWindow) {
            controller.deleteTransition(id: id, selecting: editorSelection(for: target) ?? .project)
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
        Button(controller.movingTimelineClipID == clip.id ? "Finish Moving Clip" : "Select Clip for Moving") {
            controller.toggleClipMovement(id: clip.id)
        }
        Menu("Move To…") {
            ForEach(TimelineMoveDestination.allCases, id: \.self) { destination in
                Button(destination.title) { controller.moveClip(to: destination, targetID: clip.id) }
                    .disabled(!controller.canMoveClip(to: destination, targetID: clip.id))
            }
        }
        Divider()
        Button("Delete from Timeline", role: .destructive) {
            deleteTimelineClip(clip.id)
        }
    }

    private func clipAccessibilityValue(_ clip: TimelineClip) -> String {
        TimelineAccessibility.clipValue(
            isCurrent: currentClipID == clip.id,
            isSelected: controller.movingTimelineClipID == clip.id
        )
    }

    private func performTimelineKey(_ action: TimelineKeyAction, _ target: TimelineElementSelection) {
        if action == .openEditor { activateTimelineElement(target); return }
        if action == .delete { deleteTimelineElement(target); return }
        guard case .clip(let id) = target else { return }
        switch action {
        case .toggleMovement: controller.toggleClipMovement(id: id)
        case .beginMovement: controller.beginClipMovement(id: id)
        case .finishMovement: controller.finishClipMovement()
        case .cancelMovement: controller.cancelClipMovement()
        case .delete: break
        case .earlier: controller.moveFocusedTimelineClip(id: id, by: -1)
        case .later: controller.moveFocusedTimelineClip(id: id, by: 1)
        case .copy: controller.copyTimelineClip(id: id)
        case .paste: controller.pasteCopiedTimelineClip(after: id)
        case .moveAfter: controller.moveCopiedTimelineClip(after: id)
        case .previewBefore: _ = controller.previewClipMovement(to: .before, targetID: id)
        case .previewAfter: _ = controller.previewClipMovement(to: .after, targetID: id)
        case .openEditor: break
        }
    }

    private func finishClipDeletion(_ clipID: UUID, confirmed: Bool, window: NSWindow) {
        guard let clip = clipPendingDeletion, clip.id == clipID else { return }
        let fallback = fallbackFocusAfterDeletingClip(clipID)
        clipPendingDeletion = nil
        if confirmed {
            deleteAfterFocusing(fallback, in: window) {
                controller.deleteTimelineClip(
                    id: clipID,
                    selecting: editorSelection(for: fallback) ?? .project
                )
            }
        } else {
            restoreTimelineElementFocus(to: .clip(clipID))
        }
    }

    private func deleteAfterFocusing(
        _ target: TimelineElementSelection?,
        in window: NSWindow?,
        commit: @escaping () -> Void
    ) {
        DispatchQueue.main.async {
            commit()
            guard window?.isKeyWindow == true, window?.attachedSheet == nil else { return }
            if let target { controller.requestTimelineFocusRestore(to: target) }
            else if timelineElements.isEmpty { controller.requestTimelineListFocusRestore() }
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
                    } catch { presentTimelineError(error) }
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
                    } catch { presentTimelineError(error) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func canMoveActiveTrack(by offset: Int) -> Bool {
        guard let id = controller.activeTimelineTrackID else { return false }
        return controller.project.canMoveTrack(id: id, by: offset)
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
        guard let track else { return }
        do {
            let clipID = try controller.placeThrowing(
                .append,
                editing: .asset(asset.id),
                segments: asset.sourceEdit,
                onTrack: track.id
            )
            controller.requestTimelineFocusRestore(to: .clip(clipID))
        } catch {
            errorTitle = "Clip Could Not Be Appended to Track"
            errorMessage = error.localizedDescription + " Destination track: \(track.name)."
        }
    }

    private func presentTimelineError(_ error: Error) {
        errorTitle = "Timeline Change Failed"
        errorMessage = error.localizedDescription
    }

}

/// NSAlert supplies a completion callback after its native sheet ends; SwiftUI's
/// alert button action runs before that dismissal has finished.
struct TimelineClipDeletionAlertBridge: NSViewRepresentable {
    let clip: TimelineClip?
    let completed: (UUID, Bool, NSWindow) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.owner = context.coordinator
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: Anchor, context: Context) {
        context.coordinator.update(clip: clip, parent: view.window, completed: completed)
    }

    static func dismantleNSView(_ view: Anchor, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    final class Anchor: NSView {
        weak var owner: Coordinator?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            owner?.parent = window
            owner?.presentIfPossible()
        }
    }

    @MainActor final class Coordinator {
        weak var parent: NSWindow?
        private var clip: TimelineClip?
        private var presentedClipID: UUID?
        private var alert: NSAlert?
        private var completed: ((UUID, Bool, NSWindow) -> Void)?

        func update(clip: TimelineClip?, parent: NSWindow?, completed: @escaping (UUID, Bool, NSWindow) -> Void) {
            self.clip = clip
            self.parent = parent
            self.completed = completed
            if clip == nil { presentedClipID = nil }
            presentIfPossible()
        }

        func presentIfPossible() {
            guard alert == nil, let clip, presentedClipID != clip.id,
                  let parent, parent.isKeyWindow, parent.attachedSheet == nil else { return }
            let alert = NSAlert()
            alert.messageText = TimelineClipDeletionConfirmation.title
            alert.informativeText = TimelineClipDeletionConfirmation.message(clipName: clip.displayName)
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Delete Clip").hasDestructiveAction = true
            self.alert = alert
            presentedClipID = clip.id
            alert.beginSheetModal(for: parent) { [weak self, weak parent] response in
                guard let self, let parent, self.presentedClipID == clip.id else { return }
                self.alert = nil
                self.completed?(clip.id, response == .alertSecondButtonReturn, parent)
            }
        }

        func invalidate() {
            presentedClipID = nil
            completed = nil
            clip = nil
            if let alert {
                alert.window.sheetParent?.endSheet(alert.window)
                alert.window.orderOut(nil)
            }
            alert = nil
        }
    }
}

private struct AddTrackView: View {
    let add: (TimelineTrackKind, String) -> Void
    let cancel: () -> Void

    @State private var trackName = ""
    @State private var trackKind = TimelineTrackKind.audio

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Track")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Picker("Track Type", selection: $trackKind) {
                ForEach(TimelineTrackKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            LabeledContent("Track Name") {
                TextField("Track name", text: $trackName)
                    .labelsHidden()
            }
            HStack {
                Button("Cancel", role: .cancel, action: cancel)
                Button("Add Track") { add(trackKind, trackName) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
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
        for element in elements[..<index].reversed() {
            if case .clip(let clip) = element.content { return .clip(clip.id) }
        }
        for element in elements.dropFirst(index + 1) {
            if case .clip(let clip) = element.content { return .clip(clip.id) }
        }
        return nil
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
