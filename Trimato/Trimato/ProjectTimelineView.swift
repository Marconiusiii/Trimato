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
    static let title = "Remove from Timeline?"

    static func message(clipName: String?) -> String {
        guard let clipName else {
            return "Remove this clip from the timeline? This can be undone."
        }
        return "Remove \(clipName) from the timeline? This can be undone."
    }
}

nonisolated enum TimelineTrackDeletionConfirmation {
    static let title = "Delete Track?"

    static func isRequired(for track: TimelineTrack) -> Bool {
        !track.clips.isEmpty || !track.captionCues.isEmpty || !track.markers.isEmpty
    }

    static func message(trackName: String) -> String {
        "Delete \(trackName) and all of its timeline content? This can be undone."
    }
}

struct TimelineClipRemovalRequest: Identifiable {
    let id = UUID()
    let trackID: UUID
    let clipIDs: Set<UUID>
    let origin: UUID
    let message: String
}

struct ProjectTimelineView: View {
    @AppStorage(AppPreferenceKey.precisionTimecode) private var precisionTimecode = true
    @ObservedObject var controller: ProjectController
    let openClipEditor: (EditorSelection) -> Void
    var openCaptionEditor: (CaptionCue) -> Void = { _ in }
    let workspacePaneLinks: Namespace.ID

    @State private var nativeTimelineFocus = TimelineNativeFocus()
    @State private var keyboardFocusedElement: TimelineElementSelection?
    @State private var focusedElement: TimelineElementSelection?
    @State private var renamedClipName = ""
    @State private var isRenamingClip = false
    @State private var isRenamingTrack = false
    @State private var trackName = ""
    @State private var isAddingTrack = false
    @State private var transitionFocusReturn: TimelineElementSelection?
    @State private var trackPendingDeletion: TimelineTrack?
    @State private var confirmedTrackDeletionID: UUID?
    @FocusState private var trackActionsKeyboardFocused: Bool
    @State private var clipPendingDeletion: TimelineClipRemovalRequest?
    @State private var mediaPendingDeletion: MediaAssetRecord?
    @State private var mediaDeletionOrigin: UUID?
    @State private var confirmedMediaDeletion: UUID?
    @State private var clipDeletionRequest: TimelineClipRemovalRequest?
    @State private var clipDeletionWasConfirmed = false
    @State private var magneticTrackPendingConfirmation: TimelineTrack?
    @FocusState private var magneticKeyboardFocused: Bool
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
                if controller.activeTimelineTrack?.kind == .captions,
                   controller.activeTimelineTrack?.recordingPurpose != .descriptionTranscript {
                    Toggle("Show captions", isOn: Binding(
                        get: { controller.activeTimelineTrack?.isMuted != true },
                        set: controller.setCaptionsVisible
                    ))
                    .toggleStyle(.checkbox)
                }
                if let track = controller.activeTimelineTrack, track.kind == .video || track.kind == .audio {
                    Toggle("Magnetic", isOn: Binding(
                        get: { controller.activeTimelineTrack?.isMagnetic ?? false },
                        set: { enabled in
                            if enabled && !track.clips.isEmpty {
                                magneticTrackPendingConfirmation = track
                            } else { setMagnetic(track.id, enabled: enabled) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .disabled(track.role != .additional)
                    .focused($magneticKeyboardFocused)
                }
                Menu("Track Actions") {
                    Button("Add Track…") { beginAddTrack() }
                    Button("Rename Track…") { beginRenameTrack() }
                        .disabled(controller.activeTimelineTrack == nil || controller.activeTimelineTrack?.kind == .captions)
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
                    Button("Delete Track", role: .destructive, action: beginDeletingTrack)
                        .disabled(controller.activeTimelineTrack?.role != .additional || controller.activeTimelineTrack?.kind == .captions)
                }
                .focused($trackActionsKeyboardFocused)
            }
            .padding(8)
            Divider()
            timelineContent
            Divider()
            HStack {
                Menu("Selected Element Actions") { selectedElementActions }
                    .disabled(!hasSelectedElement)
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
            nativeFocus: nativeTimelineFocus,
            allowsNudging: { element in
                guard case .clip(let id) = element else { return false }
                return controller.canNudgeTimelineClip(id: id)
            },
            contains: { target in timelineCollectionItems.contains { $0.selection == target } },
            perform: performTimelineKey
        ))
        .onChange(of: keyboardFocusedElement) { _, element in
            controller.timelineHasKeyboardFocus = element != nil
            if !NSWorkspace.shared.isVoiceOverEnabled, let element { controller.focusTimelineElement(element) }
        }
        .onAppear {
            reconcileActiveTrack()
        }
        .onChange(of: controller.workspaceFocusRequest) { _, request in
            guard request.pane == .timeline, controller.acceptsWorkspaceCommands else { return }
            controller.requestTimelineListFocusRestore()
        }
        .onChange(of: controller.project.tracks.map(\.id)) {
            reconcileActiveTrack()
        }
        .onChange(of: focusedElement) { _, element in
            guard let element else { return }
            controller.focusTimelineElement(element)
        }
        .sheet(item: $magneticTrackPendingConfirmation, onDismiss: {
            magneticKeyboardFocused = true
        }) { track in
            ConfirmationView(
                title: "Enable Magnetic for \(track.name)?",
                message: "The first clip will move to the beginning of the project, and every following clip will move directly after the previous clip. This removes all gaps and changes the clips’ synchronization with the project. You can undo this change.",
                confirmTitle: "Enable Magnetic and Reposition Clips",
                cancel: { magneticTrackPendingConfirmation = nil },
                confirm: {
                    magneticTrackPendingConfirmation = nil
                    setMagnetic(track.id, enabled: true)
                }
            )
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
        .sheet(item: $trackPendingDeletion, onDismiss: finishTrackDeletion) { track in
            ConfirmationView(
                title: TimelineTrackDeletionConfirmation.title,
                message: TimelineTrackDeletionConfirmation.message(trackName: track.name),
                confirmTitle: "Delete Track",
                cancel: { trackPendingDeletion = nil },
                confirm: {
                    confirmedTrackDeletionID = track.id
                    trackPendingDeletion = nil
                }
            )
        }
        .sheet(item: $clipPendingDeletion, onDismiss: finishClipDeletion) { clip in
            ConfirmationView(
                title: TimelineClipDeletionConfirmation.title,
                message: clip.message,
                confirmTitle: "Remove from Timeline",
                cancel: { clipPendingDeletion = nil },
                confirm: { confirmClipDeletion() }
            )
        }
        .sheet(item: $mediaPendingDeletion, onDismiss: finishMediaDeletion) { asset in
            ConfirmationView(
                title: ProjectSourceDeletionConfirmation.title,
                message: ProjectSourceDeletionConfirmation.message(clipName: asset.name,
                    timelineUseCount: controller.project.sourceAssetTimelineUseCount(asset.id)),
                confirmTitle: "Delete Media",
                cancel: { mediaPendingDeletion = nil },
                confirm: {
                    confirmedMediaDeletion = asset.id
                    mediaPendingDeletion = nil
                }
            )
        }
        .applicationMessage(errorMessage.map {
            ApplicationMessageDescriptor(title: errorTitle, message: $0)
        }) {
            errorMessage = nil
        }
    }

    @ViewBuilder
    private var timelineContent: some View {
        timelineScrollView
            .onDeleteCommand(perform: deleteFocusedTimelineElement)
    }

    private func deleteFocusedTimelineElement() {
        let target = TimelineKeyAction.target(
            voiceOver: NSWorkspace.shared.isVoiceOverEnabled,
            accessibilityFocus: nativeTimelineFocus.voiceOverSelection,
            keyboardFocus: nativeTimelineFocus.keyboardSelection,
            editingText: (NSApp.keyWindow?.firstResponder as? NSTextView)?.isEditable == true
        )
        switch target {
        case .clip(let id):
            deleteTimelineClip(id)
        case .transition(let id):
            deleteTimelineTransition(id)
        case .marker(let id): controller.deleteMarker(id)
        case .caption(let id):
            deleteCaptionCue(id)
        case nil:
            break
        }
    }

    private var timelineScrollView: some View {
        let navigation = controller.workspaceNavigation
        return TimelineClipsCollection(
            items: timelineCollectionItems,
            accessibilityLabel: timelineListAccessibilityLabel,
            emptyTitle: controller.activeTimelineTrack?.recordingPurpose == .descriptionTranscript
                ? "No descriptions on this track" : controller.activeTimelineTrack?.kind == .captions
                ? "No captions on this track" : controller.activeTimelineTrack?.kind == .markers
                ? "No markers on this track" : "No clips on this track",
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
                movePlayheadToCaption: controller.movePlayheadToCaption,
                delete: deleteTimelineElement,
                deleteMedia: beginDeletingMedia,
                selectionChanged: { controller.selectedTimelineClipIDs = $0 },
                deleteClips: { beginRemovingClips($0) }
            ),
            nativeFocus: nativeTimelineFocus,
            selectedClipIDs: controller.selectedTimelineClipIDs,
            selectionScopeID: controller.activeTimelineTrack?.id,
            keyboardFocusArrived: { target, itemRevision, listRevision in
                controller.timelineTrackKeyboardFocusArrived(target, itemRevision: itemRevision, listRevision: listRevision)
            },
            isFocusRequestCurrent: {
                navigation.pane == .timeline && controller.workspaceNavigation == navigation
            }
        )
        .frame(minHeight: 88)
    }

    private func emptyMessage(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(EditorTheme.secondaryText)
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
                    accessibilityHint: "Enter opens Cutting Board. Space toggles selection for moving.",
                    isSelected: controller.movingTimelineClipID.map { $0 == clip.id }
                        ?? controller.selectedTimelineClipIDs.contains(clip.id),
                    isTransition: false,
                    sourceMissing: controller.mediaFiles.missingIDs.contains(clip.assetID)
                )
            case .transition(let transition):
                return TimelineCollectionItemModel(
                    selection: .transition(transition.id),
                    title: transition.displayName,
                    subtitle: transitionContextDescription(transition),
                    accessibilityValue: "",
                    accessibilityHint: "Enter opens the transition editor.",
                    isSelected: controller.movingTimelineClipID == nil && controller.selection == .transition(transition.id),
                    isTransition: true
                )
            case .marker(let marker):
                return TimelineCollectionItemModel(selection: .marker(marker.id), title: marker.title,
                    subtitle: "\(marker.type.rawValue), Position: \(AppPreferences.passiveTimecode(seconds: marker.time.seconds, precision: precisionTimecode))",
                    accessibilityValue: "", accessibilityHint: "",
                    isSelected: controller.selectedMarkerID == marker.id, isTransition: false)
            case .caption(let cue):
                return TimelineCollectionItemModel(
                    selection: .caption(cue.id),
                    title: cue.displayName,
                    subtitle: nil,
                    accessibilityValue: "",
                    accessibilityHint: cue.isDescription ? "Enter opens Describer." : "Enter edits the caption.",
                    isSelected: controller.movingTimelineClipID == nil && controller.selectedCaptionCueID == cue.id,
                    isTransition: false,
                    isDescription: cue.isDescription
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
        case .marker(let id): controller.deleteMarker(id)
        case .caption(let id): deleteCaptionCue(id)
        }
    }

    private var hasSelectedElement: Bool {
        !controller.selectedTimelineClipIDs.isEmpty || controller.selectedTimelineClip != nil || selectedTimelineTransition != nil || controller.selectedCaptionCue != nil
    }

    private var selectedTimelineTransition: TimelineTransition? {
        guard let selected = controller.selectedTransition,
              let track = controller.activeTimelineTrack else { return nil }
        return TimelineElementSequence.transitions(for: track, in: controller.project)
            .first { $0.id == selected.id }
    }

    @ViewBuilder
    private var selectedElementActions: some View {
        if controller.selectedTimelineClipIDs.count > 1 {
            Button("Remove \(controller.selectedTimelineClipIDs.count) Clips from Timeline…", role: .destructive) {
                beginRemovingClips(controller.selectedTimelineClipIDs)
            }
        } else if let clip = controller.selectedTimelineClip {
            clipActions(clip)
        } else if let transition = selectedTimelineTransition {
            Button("Edit Transition…") { beginEditingTransition(transition) }
            Button("Delete Transition", role: .destructive) {
                deleteTimelineTransition(transition.id)
            }
        } else if let cue = controller.selectedCaptionCue {
            Button(cue.isDescription ? "Move Playhead to Description" : "Move Playhead to Caption") { controller.movePlayheadToCaption(id: cue.id) }
            Divider()
            Button(cue.isDescription ? "Edit Description…" : "Edit Caption…") { openCaptionEditor(cue) }
            Button(cue.isDescription ? "Delete Description" : "Delete Caption", role: .destructive) { deleteCaptionCue(cue.id) }
        }
    }

    private func beginEditingTransition(_ transition: TimelineTransition) {
        guard let clipID = transition.trailingClipID ?? transition.leadingClipID else { return }
        controller.openTransitionTool(TransitionRequest(trackID: transition.trackID, clipID: clipID, mode: .standard),
            returnsToEditor: false, editing: transition, delete: { deleteTimelineTransition(transition.id) })
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
        case .caption, .marker: nil
        case nil: nil
        }
    }

    private func restoreTimelineElementFocus() {
        guard let target = transitionFocusReturn else { return }
        transitionFocusReturn = nil
        restoreTimelineElementFocus(to: target)
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
        case .marker(let id): controller.editMarker(id)
        case .caption(let id):
            guard let cue = controller.project.captionCue(id: id) else { return }
            controller.selectedCaptionCueID = id
            openCaptionEditor(cue)
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

    private func beginDeletingMedia(_ clipID: UUID) {
        guard let clip = controller.project.timelineClip(id: clipID),
              let asset = controller.project.asset(id: clip.assetID) else { return }
        controller.selection = .timelineClip(clipID)
        focusedElement = nil; keyboardFocusedElement = nil
        mediaDeletionOrigin = clipID
        confirmedMediaDeletion = nil
        mediaPendingDeletion = asset
    }

    private func finishMediaDeletion() {
        guard let origin = mediaDeletionOrigin else { return }
        let assetID = confirmedMediaDeletion
        let fallback = assetID.flatMap { TimelineElementSequence.focusTargetAfterDeletingMedia($0, clipID: origin, from: timelineElements) }
        mediaDeletionOrigin = nil; confirmedMediaDeletion = nil
        guard let assetID else { restoreTimelineElementFocus(to: .clip(origin)); return }
        let window = NSApp.keyWindow
        DispatchQueue.main.async {
            controller.deleteSourceAsset(assetID)
            controller.selection = editorSelection(for: fallback) ?? .project
            controller.setProjectInfoTarget(.selection(controller.selection))
            guard window?.isKeyWindow == true, window?.attachedSheet == nil else { return }
            if let fallback { controller.requestTimelineFocusRestore(to: fallback) }
            else { controller.requestTimelineListFocusRestore() }
        }
    }

    private func deleteTimelineClip(_ id: UUID) {
        let selected = controller.selectedTimelineClipIDs
        beginRemovingClips(selected.contains(id) ? selected : [id], origin: id)
    }

    private func beginRemovingClips(_ ids: Set<UUID>, origin: UUID? = nil) {
        guard let track = controller.activeTimelineTrack, !ids.isEmpty,
              ids.isSubset(of: Set(track.clips.map(\.id))),
              let first = track.sortedClips.first(where: { ids.contains($0.id) }) else { return }
        let request = TimelineClipRemovalRequest(trackID: track.id, clipIDs: ids,
            origin: origin ?? first.id,
            message: ids.count == 1 ? TimelineClipDeletionConfirmation.message(clipName: first.displayName)
                : "Remove \(ids.count) clips from \(track.name)? This can be undone.")
        focusedElement = nil
        keyboardFocusedElement = nil
        clipDeletionRequest = request
        clipDeletionWasConfirmed = false
        clipPendingDeletion = request
    }

    private func deleteTimelineTransition(_ id: UUID) {
        guard let transition = controller.project.transition(id: id) else { return }
        let target = fallbackFocusAfterDeleting(transition)
        commitDeletionAndRestoreFocus(target, in: NSApp.keyWindow) {
            controller.deleteTransition(id: id, selecting: editorSelection(for: target) ?? .project)
        }
    }

    private func deleteCaptionCue(_ id: UUID) {
        let cues = controller.activeTimelineTrack?.sortedCaptionCues ?? []
        let index = cues.firstIndex { $0.id == id }
        let target = index.flatMap { position -> TimelineElementSelection? in
            if position > 0 { return .caption(cues[position - 1].id) }
            if position + 1 < cues.count { return .caption(cues[position + 1].id) }
            return nil
        }
        do {
            try controller.deleteCaptionCue(id: id)
            if let target { controller.requestTimelineFocusRestore(to: target) }
            else { controller.requestTimelineListFocusRestore() }
        } catch { presentTimelineError(error) }
    }

    private func setMagnetic(_ id: UUID, enabled: Bool) {
        do { try controller.setTrackMagnetic(id: id, enabled: enabled) }
        catch { presentTimelineError(error) }
    }

    @ViewBuilder
    private func clipActions(_ clip: TimelineClip) -> some View {
        Button("Open Cutting Board") { openClipEditor(.timelineClip(clip.id)) }
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
        Button("Remove from Timeline", role: .destructive) {
            deleteTimelineClip(clip.id)
        }
        Button("Delete Media", role: .destructive) { beginDeletingMedia(clip.id) }
    }

    private func clipAccessibilityValue(_ clip: TimelineClip) -> String {
        TimelineAccessibility.clipValue(
            isCurrent: currentClipID == clip.id,
            isSelected: controller.movingTimelineClipID == clip.id || controller.selectedTimelineClipIDs.contains(clip.id)
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

    private func beginDeletingTrack() {
        guard let track = controller.activeTimelineTrack, track.role == .additional, track.kind != .captions else { return }
        confirmedTrackDeletionID = nil
        if TimelineTrackDeletionConfirmation.isRequired(for: track) {
            trackPendingDeletion = track
        } else {
            commitTrackDeletion(track.id)
        }
    }

    private func finishTrackDeletion() {
        guard let id = confirmedTrackDeletionID else {
            trackActionsKeyboardFocused = true
            return
        }
        confirmedTrackDeletionID = nil
        commitTrackDeletion(id)
    }

    private func commitTrackDeletion(_ id: UUID) {
        do {
            try controller.deleteTrack(id: id)
            controller.requestTimelineListFocusRestore()
        } catch { presentTimelineError(error) }
    }

    private func confirmClipDeletion() {
        clipDeletionWasConfirmed = true
        clipPendingDeletion = nil
    }

    private func finishClipDeletion() {
        guard let request = clipDeletionRequest else { return }
        let confirmed = clipDeletionWasConfirmed
        clipDeletionRequest = nil
        clipDeletionWasConfirmed = false
        if confirmed {
            guard controller.activeTimelineTrack?.id == request.trackID else { return }
            let fallback = TimelineElementSequence.focusTargetAfterDeletingClips(request.clipIDs, from: timelineElements)
            do {
                try controller.removeTimelineClips(request.clipIDs, from: request.trackID,
                    selecting: editorSelection(for: fallback) ?? .project)
                if let fallback { controller.requestTimelineFocusRestore(to: fallback) }
                else { controller.requestTimelineListFocusRestore() }
            } catch { presentTimelineError(error) }
        } else {
            restoreTimelineElementFocus(to: .clip(request.origin))
        }
    }

    private func commitDeletionAndRestoreFocus(
        _ target: TimelineElementSelection?,
        in window: NSWindow?,
        commit: @escaping () -> Void
    ) {
        DispatchQueue.main.async {
            commit()
            guard window?.isKeyWindow == true, window?.attachedSheet == nil else { return }
            if let target { controller.requestTimelineFocusRestore(to: target) }
            else { controller.requestTimelineListFocusRestore() }
        }
    }

    private var renameClipSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Timeline Clip").font(.headline).accessibilityAddTraits(.isHeader)
            LabeledContent("Timeline Clip Name") {
                TextField("Timeline Clip Name", text: $renamedClipName, prompt: Text(""))
                    .labelsHidden()
            }
            NativeModalActions(
                primaryTitle: "Rename",
                cancel: { isRenamingClip = false }
            ) {
                do {
                    try controller.renameTimelineEntry(controller.selection, to: renamedClipName)
                    isRenamingClip = false
                } catch { presentTimelineError(error) }
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var renameTrackSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Track").font(.headline).accessibilityAddTraits(.isHeader)
            LabeledContent("Track Name") {
                TextField("Track Name", text: $trackName, prompt: Text(""))
                    .labelsHidden()
            }
            NativeModalActions(
                primaryTitle: "Rename",
                cancel: { isRenamingTrack = false }
            ) {
                do {
                    try controller.renameActiveTrack(to: trackName)
                    isRenamingTrack = false
                } catch { presentTimelineError(error) }
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
                ForEach([TimelineTrackKind.video, .audio]) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            LabeledContent("Track Name") {
                TextField("Track name", text: $trackName, prompt: Text(""))
                    .labelsHidden()
            }
            NativeModalActions(
                primaryTitle: "Add Track",
                cancel: cancel,
                primary: { add(trackKind, trackName) }
            )
        }
        .padding(20)
        .frame(width: 380)
    }
}

struct TimelineListElement: Identifiable, Equatable {
    enum Content {
        case clip(TimelineClip)
        case transition(TimelineTransition)
        case caption(CaptionCue)
        case marker(TimelineMarker)
    }

    let content: Content

    var id: String {
        switch content {
        case .clip(let clip): "clip-\(clip.id.uuidString)"
        case .transition(let transition): "transition-\(transition.id.uuidString)"
        case .marker(let marker): "marker-\(marker.id.uuidString)"
        case .caption(let cue): "caption-\(cue.id.uuidString)"
        }
    }
}

extension TimelineListElement.Content: Equatable {}

enum TimelineElementSequence {
    static func focusTargetAfterDeletingMedia(_ assetID: UUID, clipID: UUID,
                                             from elements: [TimelineListElement]) -> TimelineElementSelection? {
        guard let index = elements.firstIndex(where: {
            if case .clip(let clip) = $0.content { return clip.id == clipID }; return false
        }) else { return nil }
        for element in Array(elements.dropFirst(index + 1)) + Array(elements[..<index].reversed()) {
            if case .clip(let clip) = element.content, clip.assetID != assetID { return .clip(clip.id) }
        }
        return nil
    }

    static func focusTargetAfterDeletingClip(
        _ clipID: UUID,
        from elements: [TimelineListElement]
    ) -> TimelineElementSelection? {
        focusTargetAfterDeletingClips([clipID], from: elements)
    }

    static func focusTargetAfterDeletingClips(
        _ clipIDs: Set<UUID>, from elements: [TimelineListElement]
    ) -> TimelineElementSelection? {
        guard let index = elements.lastIndex(where: {
            if case .clip(let clip) = $0.content { return clipIDs.contains(clip.id) }
            return false
        }) else { return nil }
        for element in Array(elements.dropFirst(index + 1)) + Array(elements[..<index].reversed()) {
            if case .clip(let clip) = element.content, !clipIDs.contains(clip.id) { return .clip(clip.id) }
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
        if track.kind == .markers { return track.sortedMarkers.map { TimelineListElement(content: .marker($0)) } }
        if track.kind == .captions {
            return track.sortedCaptionCues.map { TimelineListElement(content: .caption($0)) }
        }
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
    static func string(_ time: ProjectTime, milliseconds: Bool = AppPreferences.showMilliseconds()) -> String {
        AppPreferences.passiveTimecode(seconds: time.seconds, precision: milliseconds)
    }
}
