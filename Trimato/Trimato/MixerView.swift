import AppKit
import Combine
import SwiftUI

struct MixerTrack: Equatable, Identifiable {
    let id: UUID
    let name: String
    let mix: TrackMixSettings
    let muted: Bool
}

@MainActor
final class MixerSession: ObservableObject {
    let controller: ProjectController
    let player: ProjectPlayerViewModel
    @Published private(set) var tracks: [MixerTrack] = []
    @Published var selectedID: UUID?
    @Published private(set) var soloIDs: Set<UUID> = []
    @Published private(set) var masterVolumeDB: Double = 0
    private var observation: AnyCancellable?
    private let fromTimeline: Bool
    private let origin: TimelineElementSelection?

    init(controller: ProjectController, player: ProjectPlayerViewModel) {
        self.controller = controller; self.player = player
        fromTimeline = controller.timelineHasKeyboardFocus || TimelineKeyboardFocus.isInTimeline
        origin = controller.selectedTimelineClip.map { .clip($0.id) }
        refresh()
        selectedID = tracks.contains(where: { $0.id == controller.activeTimelineTrackID })
            ? controller.activeTimelineTrackID : tracks.first?.id
        observation = controller.document.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
    }
    var selected: MixerTrack? { tracks.first { $0.id == selectedID } }
    func refresh() {
        let next = controller.project.orderedTimelineTracks.filter { $0.kind == .audio }.map {
            MixerTrack(id: $0.id, name: $0.name, mix: $0.mix, muted: $0.isMuted)
        }
        if next != tracks { tracks = next }
        if !tracks.contains(where: { $0.id == selectedID }) { selectedID = tracks.first?.id }
        if masterVolumeDB != controller.project.masterVolumeDB { masterVolumeDB = controller.project.masterVolumeDB }
        let validSolo = soloIDs.intersection(Set(tracks.map(\.id)))
        if validSolo != soloIDs { soloIDs = validSolo }
        player.updateMix(project: controller.project, solo: soloIDs)
    }
    func change(_ key: WritableKeyPath<TrackMixSettings, Double>, to value: Double) {
        guard let track = selected else { return }
        var mix = track.mix; mix[keyPath: key] = value
        controller.setTrackMix(track.id, settings: mix); refresh()
    }
    func route(_ route: TrackChannelRouting) {
        guard let track = selected else { return }
        var mix = track.mix; mix.routing = route
        controller.setTrackMix(track.id, settings: mix); refresh()
    }
    func mute(_ value: Bool) {
        guard let selectedID else { return }
        controller.setMixerTrackMuted(selectedID, muted: value); refresh()
    }
    func solo(_ value: Bool) {
        guard let selectedID else { return }
        if value { soloIDs.insert(selectedID) } else { soloIDs.remove(selectedID) }
        player.updateMix(project: controller.project, solo: soloIDs)
    }
    func reset() {
        guard let selectedID else { return }
        soloIDs.remove(selectedID)
        controller.resetTrackMix(selectedID); refresh()
    }
    func close() {
        controller.mixerAdjustmentEditing(false)
        player.updateMix(project: controller.project, solo: [])
        guard controller.projectSaveCoordinator?.isApplicationTerminating != true,
              controller.projectSaveCoordinator?.isResolvingClose != true,
              ExternalMediaOpenCoordinator.shared.activeProjectController === controller,
              let window = controller.projectSaveCoordinator?.attachedWindow, window.isVisible else { return }
        window.makeKeyAndOrderFront(nil)
        if fromTimeline {
            if let origin { controller.requestTimelineFocusRestore(to: origin) }
            else { controller.requestTimelineListFocusRestore() }
        } else { controller.requestEditorFocusRestore() }
    }
}

@MainActor
final class MixerWindowRegistry: ObservableObject {
    static let shared = MixerWindowRegistry()
    @Published var session: MixerSession?
    func open(controller: ProjectController) {
        guard session == nil, let player = controller.projectPlayer else { return }
        session = MixerSession(controller: controller, player: player)
    }
}

private struct CloseMixerKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var closeMixer: (() -> Void)? {
        get { self[CloseMixerKey.self] }
        set { self[CloseMixerKey.self] = newValue }
    }
}

struct MixerWindowContent: View {
    @ObservedObject private var registry = MixerWindowRegistry.shared
    @ObservedObject private var projects = ExternalMediaOpenCoordinator.shared
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        Group {
            if let session = registry.session, let coordinator = session.controller.projectSaveCoordinator {
                MixerWindowEditor(session: session, coordinator: coordinator)
                    .blocksEditingDuringQuit()
                    .focusedSceneObject(session)
                    .focusedSceneObject(session.controller)
                    .focusedSceneObject(session.player)
                    .focusedSceneValue(\.closeMixer, { dismissWindow(id: "mixer") })
                    .onDisappear {
                        session.close()
                        if registry.session === session { registry.session = nil }
                    }
            } else {
                Text("No project open")
            }
        }
        .onChange(of: projects.activeProjectController?.project.id) { _, id in
            if id != registry.session?.controller.project.id { dismissWindow(id: "mixer") }
        }
    }
}

private struct MixerWindowEditor: View {
    let session: MixerSession
    @ObservedObject var coordinator: ProjectWindowSaveCoordinator
    var body: some View {
        MixerView(session: session)
            .disabled(coordinator.isConfirmingClose || coordinator.isResolvingClose)
    }
}

struct MixerView: View {
    @ObservedObject var session: MixerSession
    @FocusState private var volumeKeyboardFocus: Bool
    @AccessibilityFocusState private var volumeAccessibilityFocus: Bool

    private func value(_ key: WritableKeyPath<TrackMixSettings, Double>) -> Binding<Double> {
        Binding(get: { session.selected?.mix[keyPath: key] ?? TrackMixSettings.neutral[keyPath: key] },
                set: { session.change(key, to: $0) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if session.tracks.isEmpty {
                Text("Add an audio track to use the Mixer.")
            }
            MixerTrackCollection(tracks: session.tracks, selectedID: session.selectedID, soloIDs: session.soloIDs,
                select: { session.selectedID = $0 }, play: { session.player.togglePlayback() },
                edit: { volumeKeyboardFocus = true; volumeAccessibilityFocus = true },
                shuttle: { key in
                    if key == "j" { session.player.pressJ() }
                    else if key == "k" { session.player.pressK() }
                    else { session.player.pressL() }
                }, navigate: { code in
                    switch code {
                    case 123: session.player.goToPreviousEdit()
                    case 124: session.player.goToNextEdit()
                    case 126: session.player.goToStart()
                    default: session.player.goToEnd()
                    }
                })
                .frame(height: 100)
            MacEditorPane("Track Controls") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Track Controls").font(.headline).accessibilityAddTraits(.isHeader)
                    HStack {
                    Slider(value: value(\.volumeDB), in: -60...12, step: 0.5, onEditingChanged: session.controller.mixerAdjustmentEditing) { Text("Volume") }
                        .accessibilityValue(MixerValue.decibels(session.selected?.mix.volumeDB ?? 0))
                        .focused($volumeKeyboardFocus).accessibilityFocused($volumeAccessibilityFocus)
                        Text(MixerValue.decibels(session.selected?.mix.volumeDB ?? 0)).monospacedDigit().frame(width: 150, alignment: .trailing).accessibilityHidden(true)
                    }
                    Toggle("Mute", isOn: Binding(get: { session.selected?.muted ?? false }, set: session.mute))
                    Toggle("Solo", isOn: Binding(get: { session.selectedID.map { session.soloIDs.contains($0) } ?? false }, set: session.solo))
                    HStack {
                    Slider(value: value(\.pan), in: -1...1, step: 0.01, onEditingChanged: session.controller.mixerAdjustmentEditing) { Text("Pan") }
                        .accessibilityValue(MixerValue.position(session.selected?.mix.pan ?? 0))
                        Text(MixerValue.position(session.selected?.mix.pan ?? 0)).monospacedDigit().frame(width: 150, alignment: .trailing).accessibilityHidden(true)
                    }
                    HStack {
                    Slider(value: value(\.balance), in: -1...1, step: 0.01, onEditingChanged: session.controller.mixerAdjustmentEditing) { Text("Stereo balance") }
                        .accessibilityValue(MixerValue.position(session.selected?.mix.balance ?? 0))
                        Text(MixerValue.position(session.selected?.mix.balance ?? 0)).monospacedDigit().frame(width: 150, alignment: .trailing).accessibilityHidden(true)
                    }
                    HStack {
                    Slider(value: value(\.width), in: 0...2, step: 0.01, onEditingChanged: session.controller.mixerAdjustmentEditing) { Text("Stereo width") }
                        .accessibilityValue(MixerValue.width(session.selected?.mix.width ?? 1))
                        Text(MixerValue.width(session.selected?.mix.width ?? 1)).monospacedDigit().frame(width: 150, alignment: .trailing).accessibilityHidden(true)
                    }
                    Picker("Channel routing", selection: Binding(get: { session.selected?.mix.routing ?? .both }, set: session.route)) {
                        ForEach(TrackChannelRouting.allCases) { Text($0.title).tag($0) }
                    }
                    Button("Reset Track Mix", action: session.reset)
                }
            }
            .disabled(session.selected == nil)
            Divider()
            MixerPlaybackView(session: session, player: session.player)
        }
        .padding(20).frame(width: 620)
        .onKeyPress(characters: CharacterSet(charactersIn: "jkl"), phases: .down) { event in
            guard event.modifiers.isEmpty, !MixerKeyRouting.textOrChoiceFocused else { return .ignored }
            switch event.characters.lowercased() {
            case "j": session.player.pressJ()
            case "k": session.player.pressK()
            case "l": session.player.pressL()
            default: return .ignored
            }
            return .handled
        }
        .onKeyPress(.space, phases: .down) { event in
            guard event.modifiers.isEmpty, !MixerKeyRouting.controlOwnsSpace else { return .ignored }
            session.player.togglePlayback(); return .handled
        }
        .onKeyPress(.leftArrow, phases: .down) { event in
            guard event.modifiers == .command else { return .ignored }
            session.player.goToPreviousEdit(); return .handled
        }
        .onKeyPress(.rightArrow, phases: .down) { event in
            guard event.modifiers == .command else { return .ignored }
            session.player.goToNextEdit(); return .handled
        }
        .onKeyPress(.upArrow, phases: .down) { event in
            guard event.modifiers == .command else { return .ignored }
            session.player.goToStart(); return .handled
        }
        .onKeyPress(.downArrow, phases: .down) { event in
            guard event.modifiers == .command else { return .ignored }
            session.player.goToEnd(); return .handled
        }
    }
}

private struct MixerPlaybackView: View {
    @ObservedObject var session: MixerSession
    @ObservedObject var player: ProjectPlayerViewModel
    var body: some View {
        MacEditorPane("Project Playback") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Project Playback").font(.headline).accessibilityAddTraits(.isHeader)
                Slider(value: Binding(get: { player.playbackFraction }, set: { player.seek(toFraction: $0) }),
                       in: 0...1, step: player.playbackFractionStep) { Text("Project playhead") }
                    .tint(EditorTheme.playhead)
                    .accessibilityValue(player.accessibilityTimecodeLabel)
                    .disabled(!player.canControlPlayback)
                HStack {
                    Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayback() }
                    Button("Go to Beginning") { player.goToStart() }
                    Button("Go to End") { player.goToEnd() }
                }.disabled(!player.canControlPlayback)
                HStack {
                Slider(value: Binding(get: { session.masterVolumeDB }, set: {
                    session.controller.setMasterVolume($0); session.refresh()
                }), in: -60...12, step: 0.5, onEditingChanged: session.controller.mixerAdjustmentEditing) { Text("Master Volume") }
                    .accessibilityValue(MixerValue.decibels(session.masterVolumeDB))
                    Text(MixerValue.decibels(session.masterVolumeDB)).monospacedDigit().frame(width: 150, alignment: .trailing).accessibilityHidden(true)
                }
            }
        }
    }
}

nonisolated enum MixerValue {
    static func decibels(_ value: Double) -> String { String(format: "%.1f dB", value) }
    static func position(_ value: Double) -> String {
        abs(value) < 0.005 ? "Center" : "\(Int((abs(value) * 100).rounded())) percent \(value < 0 ? "left" : "right")"
    }
    static func width(_ value: Double) -> String {
        if value == 0 { return "Mono" }
        if value == 1 { return "Original" }
        return "\(Int((value * 100).rounded())) percent"
    }
}


@MainActor
private enum MixerKeyRouting {
    private static var focusedRole: String? {
        let object: NSObject?
        if NSWorkspace.shared.isVoiceOverEnabled { object = NSApp.accessibilityFocusedUIElement as? NSObject }
        else { object = NSApp.keyWindow?.firstResponder }
        guard let object, object.responds(to: NSSelectorFromString("accessibilityRole")) else { return nil }
        return object.value(forKey: "accessibilityRole") as? String
    }
    static var textOrChoiceFocused: Bool {
        ["AXTextField", "AXTextArea", "AXPopUpButton", "AXComboBox", "AXMenu", "AXMenuItem"].contains(focusedRole ?? "")
    }
    static var controlOwnsSpace: Bool {
        textOrChoiceFocused || ["AXButton", "AXCheckBox", "AXRadioButton", "AXSwitch"].contains(focusedRole ?? "")
    }
}


struct MixerUndoCommands: Commands {
    @FocusedObject private var session: MixerSession?
    var body: some Commands {
        if let session {
            CommandGroup(replacing: .undoRedo) {
                Button(session.controller.mixerUndoManager?.undoMenuItemTitle ?? "Undo") {
                    session.controller.mixerAdjustmentEditing(false)
                    session.controller.mixerUndoManager?.undo()
                    session.refresh()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(session.controller.mixerUndoManager?.canUndo != true)
                Button(session.controller.mixerUndoManager?.redoMenuItemTitle ?? "Redo") {
                    session.controller.mixerUndoManager?.redo()
                    session.refresh()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(session.controller.mixerUndoManager?.canRedo != true)
            }
        }
    }
}
