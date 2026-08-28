import AppKit
import SwiftUI

struct ProjectTimelineView: View {
    @ObservedObject var controller: ProjectController
    let openClipEditor: (EditorSelection) -> Void
    let workspacePaneLinks: Namespace.ID

    @AccessibilityFocusState private var focusedElement: TimelineElementSelection?
    @State private var renamedClipName = ""
    @State private var isRenamingClip = false
    @State private var isRenamingTrack = false
    @State private var trackName = ""
    @State private var isAddingTrack = false
    @State private var editingTransition: TimelineTransition?
    @State private var transitionFocusReturn: TimelineElementSelection?
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
                Menu("Track Actions") {
                    Button("Add Track…") { beginAddTrack() }
                    Button("Rename Track…") { beginRenameTrack() }
                        .disabled(controller.activeTimelineTrack == nil)
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
        .onChange(of: controller.activeTimelineTrackID) {
            focusedElement = nil
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
    }

    @ViewBuilder
    private var timelineContent: some View {
        if controller.project.tracks.isEmpty {
            emptyMessage("No clips in the project timeline")
        } else if timelineElements.isEmpty {
            emptyMessage("No clips on this track")
        } else {
            accessibleTimelineList
            .background(
                TimelineContextMenuKeyBridge(
                    focusedElement: focusedElement,
                    activate: activateTimelineElement,
                    renameClip: beginRenamingClip,
                    deleteClip: deleteTimelineClip,
                    editTransition: editTransition,
                    deleteTransition: controller.deleteTransition,
                    copyClip: controller.copyTimelineClip,
                    pasteClipAfter: controller.pasteCopiedTimelineClip,
                    moveClipAfter: controller.moveCopiedTimelineClip
                )
                .frame(width: 0, height: 0)
            )
        }
    }

    @ViewBuilder
    private var accessibleTimelineList: some View {
        if #available(macOS 26.0, *), let currentSelection {
            timelineList
                .accessibilityDefaultFocus($focusedElement, currentSelection)
        } else {
            timelineList
        }
    }

    private var timelineList: some View {
        List {
            ForEach(timelineElements) { element in
                    switch element.content {
                    case .clip(let clip): clipButton(clip)
                    case .transition(let transition): transitionButton(transition)
                    }
            }
        }
        .listStyle(.plain)
        .accessibilityLabel(timelineAccessibilityLabel)
        .background {
            TimelineTableAccessibilityLabelBridge(label: timelineAccessibilityLabel)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var timelineAccessibilityLabel: String {
        "Timeline clips, \(controller.activeTimelineTrack?.name ?? "current track")"
    }

    private func emptyMessage(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }

    private var timelineElements: [TimelineListElement] {
        guard let track = controller.activeTimelineTrack else { return [] }
        return TimelineElementSequence.elements(
            track: track,
            transitions: controller.project.transitions.filter { $0.trackID == track.id }
        )
    }

    private var currentSelection: TimelineElementSelection? {
        controller.editorClip(at: controller.timelinePlayhead).map { .clip($0.id) }
    }

    private var activeTrackBinding: Binding<UUID?> {
        Binding(
            get: { controller.activeTimelineTrackID ?? controller.project.tracks.first?.id },
            set: { controller.activeTimelineTrackID = $0 }
        )
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
        .accessibilityValue(transitionContextDescription(transition) ?? "")
        .accessibilityFocused($focusedElement, equals: .transition(transition.id))
        .contextMenu {
            Button("Edit Transition…") { beginEditingTransition(transition) }
            Button("Delete Transition", role: .destructive) {
                controller.deleteTransition(id: transition.id)
            }
        }
    }

    private func selectionBackground(_ selection: EditorSelection) -> Color {
        controller.selection == selection ? EditorTheme.accent.opacity(0.28) : EditorTheme.raisedSurface
    }

    private var hasSelectedElement: Bool {
        controller.selectedTimelineClip != nil || controller.selectedTransition != nil
    }

    @ViewBuilder
    private var selectedElementActions: some View {
        if let clip = controller.selectedTimelineClip {
            clipActions(clip)
        } else if let transition = controller.selectedTransition {
            Button("Edit Transition…") { beginEditingTransition(transition) }
            Button("Delete Transition", role: .destructive) {
                controller.deleteTransition(id: transition.id)
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
        focusedElement = nil
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
        controller.selection = .timelineClip(id)
        controller.deleteSelection()
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
            controller.selection = .timelineClip(clip.id)
            controller.deleteSelection()
        }
    }

    private var renameClipSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Timeline Clip").font(.headline).accessibilityAddTraits(.isHeader)
            TextField("Clip Name", text: $renamedClipName)
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
            TextField("Track Name", text: $trackName)
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
        controller.activeTimelineTrackID = controller.project.tracks.first?.id
    }

    private func beginRenameTrack() {
        guard let track = controller.activeTimelineTrack else { return }
        trackName = track.name
        isRenamingTrack = true
    }

    private func beginAddTrack() {
        isAddingTrack = true
    }
}

private struct TimelineTableAccessibilityLabelBridge: NSViewRepresentable {
    let label: String

    func makeNSView(context: Context) -> TimelineTableLabelView {
        let view = TimelineTableLabelView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: TimelineTableLabelView, context: Context) {
        nsView.timelineLabel = label
        nsView.applyLabelWhenReady()
    }
}

private final class TimelineTableLabelView: NSView {
    var timelineLabel = ""

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyLabelWhenReady()
    }

    func applyLabelWhenReady() {
        DispatchQueue.main.async { [weak self] in
            self?.applyLabel()
        }
    }

    private func applyLabel() {
        guard !timelineLabel.isEmpty,
              let contentView = window?.contentView else { return }

        let labelFrame = convert(bounds, to: nil)
        let table = Self.tables(in: contentView)
            .filter { !$0.isHidden }
            .max { first, second in
                Self.intersectionArea(first.convert(first.bounds, to: nil), labelFrame)
                    < Self.intersectionArea(second.convert(second.bounds, to: nil), labelFrame)
            }

        guard let table,
              Self.intersectionArea(table.convert(table.bounds, to: nil), labelFrame) > 0 else { return }
        table.setAccessibilityLabel(timelineLabel)
    }

    private static func tables(in view: NSView) -> [NSTableView] {
        var result: [NSTableView] = []
        if let table = view as? NSTableView {
            result.append(table)
        }
        for subview in view.subviews {
            result.append(contentsOf: tables(in: subview))
        }
        return result
    }

    private static func intersectionArea(_ first: NSRect, _ second: NSRect) -> CGFloat {
        let intersection = first.intersection(second)
        return intersection.isNull ? 0 : intersection.width * intersection.height
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
            Picker("Track Type", selection: trackKindBinding) {
                ForEach(TimelineTrackKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .accessibilityFocused($trackTypeFocused)
            TextField("Track Name", text: $trackName)
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
