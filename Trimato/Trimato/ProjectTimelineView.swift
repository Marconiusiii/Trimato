import SwiftUI

struct ProjectTimelineView: View {
    @ObservedObject var controller: ProjectController
    let openClipEditor: (EditorSelection) -> Void

    @AccessibilityFocusState private var focusedElement: TimelineElementSelection?
    @State private var renamedClipName = ""
    @State private var isRenamingClip = false
    @State private var isRenamingTrack = false
    @State private var trackName = ""
    @State private var isAddingTrack = false
    @State private var editingTransition: TimelineTransition?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Text("Timeline")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
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
        .onAppear { reconcileActiveTrack() }
        .onChange(of: controller.project.tracks.map(\.id)) { _ in reconcileActiveTrack() }
        .onChange(of: focusedElement) { element in
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
        .sheet(item: $editingTransition) { transition in
            TransitionEditorView(
                transition: transition,
                update: { updated in
                    do {
                        try controller.updateTransition(updated)
                        editingTransition = nil
                    } catch { errorMessage = error.localizedDescription }
                },
                delete: {
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
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 2) {
                    ForEach(timelineElements) { element in
                        switch element.content {
                        case .clip(let clip): clipButton(clip)
                        case .transition(let transition): transitionButton(transition)
                        }
                    }
                }
                .padding(8)
            }
            .accessibilityRepresentation {
                timelineAccessibilityContent
            }
        }
    }

    private var timelineAccessibilityContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(timelineElements) { element in
                switch element.content {
                case .clip(let clip): clipButton(clip)
                case .transition(let transition): transitionButton(transition)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline clips")
    }

    private func emptyMessage(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }

    private var timelineElements: [TimelineListElement] {
        guard let track = controller.activeTimelineTrack else { return [] }
        var result = track.sortedClips.map {
            TimelineListElement(content: .clip($0), time: $0.timelineStart, order: 1)
        }
        for transition in controller.project.transitions where transition.trackID == track.id {
            let position: ProjectTime
            if let trailingID = transition.trailingClipID,
               let trailing = track.clips.first(where: { $0.id == trailingID }) {
                position = trailing.timelineStart
            } else if let leadingID = transition.leadingClipID,
                      let leading = track.clips.first(where: { $0.id == leadingID }) {
                position = transition.edge == .outro ? leading.timelineEnd : leading.timelineStart
            } else {
                position = .zero
            }
            let order = transition.edge == .intro ? 0 : 2
            result.append(TimelineListElement(content: .transition(transition), time: position, order: order))
        }
        return result.sorted {
            if $0.time == $1.time { return $0.order < $1.order }
            return $0.time < $1.time
        }
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
            VStack(alignment: .leading, spacing: 4) {
                Text(clip.displayName).lineLimit(2)
                Text(ProjectTimecodeFormatter.string(clip.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 180, alignment: .leading)
            .padding(8)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 56, alignment: .topLeading)
        .background(selectionBackground(.timelineClip(clip.id)), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(EditorTheme.separator))
        .accessibilityLabel(clip.displayName)
        .accessibilityFocused($focusedElement, equals: .clip(clip.id))
        .contextMenu { clipActions(clip) }
    }

    private func transitionButton(_ transition: TimelineTransition) -> some View {
        Button {
            controller.selection = .transition(transition.id)
            editingTransition = transition
        } label: {
            Text(transition.displayName)
                .lineLimit(2)
                .frame(width: 150, alignment: .leading)
                .padding(8)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 56, alignment: .topLeading)
        .background(selectionBackground(.transition(transition.id)), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(EditorTheme.accent.opacity(0.75)))
        .accessibilityLabel(transition.displayName)
        .accessibilityFocused($focusedElement, equals: .transition(transition.id))
        .contextMenu {
            Button("Edit Transition…") { editingTransition = transition }
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
            Button("Edit Transition…") { editingTransition = transition }
            Button("Delete Transition", role: .destructive) {
                controller.deleteTransition(id: transition.id)
            }
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

private struct TimelineListElement: Identifiable {
    enum Content {
        case clip(TimelineClip)
        case transition(TimelineTransition)
    }

    let content: Content
    let time: ProjectTime
    let order: Int

    var id: String {
        switch content {
        case .clip(let clip): "clip-\(clip.id.uuidString)"
        case .transition(let transition): "transition-\(transition.id.uuidString)"
        }
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
