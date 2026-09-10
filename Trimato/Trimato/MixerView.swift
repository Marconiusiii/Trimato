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
    func selectAdjacentTrack(_ direction: Int) {
        guard !tracks.isEmpty else { return }
        controller.mixerAdjustmentEditing(false)
        selectedID = MixerTrackNavigation.adjacent(direction, selected: selectedID, tracks: tracks.map(\.id))
    }
    func togglePlayback() { player.toggleMixerPlayback() }
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

struct MixerView: View {
    @ObservedObject var session: MixerSession
    let player: ProjectPlayerViewModel

    private func value(_ key: WritableKeyPath<TrackMixSettings, Double>) -> Binding<Double> {
        Binding(get: { session.selected?.mix[keyPath: key] ?? TrackMixSettings.neutral[keyPath: key] },
                set: { session.change(key, to: $0) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mixer").font(.title2).accessibilityAddTraits(.isHeader)
            MixerPlaybackControls(player: player, play: session.togglePlayback)
            Divider()
            Text("Track controls").font(.headline).accessibilityAddTraits(.isHeader)
            Picker("Audio track", selection: $session.selectedID) {
                ForEach(session.tracks) { Text($0.name).tag(Optional($0.id)) }
            }
            .accessibilityIdentifier("trimato.mixer.track")
            .disabled(session.tracks.isEmpty)
            Group {
                AudioValueSlider(label: "Volume", value: value(\.volumeDB), range: -60...12, step: 0.5,
                    unit: "dB", identifier: "trimato.mixer.volume", spokenValue: MixerValue.decibels,
                    onEditingChanged: session.controller.mixerAdjustmentEditing)
                Toggle("Mute", isOn: Binding(get: { session.selected?.muted ?? false }, set: session.mute))
                Toggle("Solo", isOn: Binding(get: { session.selectedID.map { session.soloIDs.contains($0) } ?? false }, set: session.solo))
                AudioValueSlider(label: "Pan", value: value(\.pan), range: -1...1, step: 0.01,
                    unit: "", identifier: "trimato.mixer.pan", spokenValue: MixerValue.position,
                    onEditingChanged: session.controller.mixerAdjustmentEditing)
                AudioValueSlider(label: "Stereo balance", value: value(\.balance), range: -1...1, step: 0.01,
                    unit: "", identifier: "trimato.mixer.balance", spokenValue: MixerValue.position,
                    onEditingChanged: session.controller.mixerAdjustmentEditing)
                AudioValueSlider(label: "Stereo width", value: value(\.width), range: 0...2, step: 0.01,
                    unit: "", identifier: "trimato.mixer.width", spokenValue: MixerValue.width,
                    onEditingChanged: session.controller.mixerAdjustmentEditing)
                Picker("Channel routing", selection: Binding(get: { session.selected?.mix.routing ?? .both }, set: session.route)) {
                    ForEach(TrackChannelRouting.allCases) { Text($0.title).tag($0) }
                }
                Button("Reset Track Mix", action: session.reset)
            }
            .disabled(session.selected == nil)
            Divider()
            AudioValueSlider(label: "Master Volume", value: Binding(get: { session.masterVolumeDB }, set: {
                session.controller.setMasterVolume($0); session.refresh()
            }), range: -60...12, step: 0.5, unit: "dB", identifier: "trimato.mixer.master",
                spokenValue: MixerValue.decibels, onEditingChanged: session.controller.mixerAdjustmentEditing)
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 760)
        .background(EditorTheme.controlSurface)
        .blocksEditingDuringQuit()
    }
}

private struct MixerPlaybackControls: View {
    @ObservedObject var player: ProjectPlayerViewModel
    let play: () -> Void
    @StateObject private var keyboard = SettingsSliderKeyboard(identifier: "trimato.mixer.playhead")
    var body: some View {
        VStack(spacing: 10) {
            if let message = player.errorMessage {
                Text(message).textSelection(.enabled)
            }
            MixerPlayheadSlider(value: Binding(get: { player.playbackFraction }, set: { player.seek(toFraction: $0) }),
                step: player.playbackFractionStep, timecode: player.accessibilityTimecodeLabel)
                .tint(EditorTheme.playhead)
                .onAppear { keyboard.start() }
                .onDisappear { keyboard.stop() }
            Button { player.toggleTimecodeDisplay() } label: {
                Text(player.accessibilityTimecodeLabel).font(.system(.title, design: .monospaced))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Project timecode")
            .accessibilityValue(player.accessibilityTimecodeLabel)
            HStack(spacing: 16) {
                Button("Step backward one frame", systemImage: "backward.frame.fill", action: player.stepBackward)
                Button("Skip back 10 seconds", systemImage: "gobackward.10", action: player.seekBackward)
                Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill", action: play)
                Button("Skip forward 10 seconds", systemImage: "goforward.10", action: player.seekForward)
                Button("Step forward one frame", systemImage: "forward.frame.fill", action: player.stepForward)
            }
            .labelStyle(.iconOnly)
            HStack {
                Button("Go to Beginning", action: player.goToStart)
                Button("Go to End", action: player.goToEnd)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback")
        .disabled(!player.canControlPlayback)
    }
}

struct MixerUndoCommands: Commands {
    @ObservedObject private var registry = MixerWindowRegistry.shared
    var body: some Commands {
        if let session = registry.activeSession {
            CommandGroup(replacing: .undoRedo) {
                Button(session.controller.mixerUndoManager?.undoMenuItemTitle ?? "Undo") {
                    session.controller.mixerAdjustmentEditing(false)
                    session.controller.mixerUndoManager?.undo(); session.refresh()
                }.keyboardShortcut("z", modifiers: .command)
                    .disabled(session.controller.mixerUndoManager?.canUndo != true)
                Button(session.controller.mixerUndoManager?.redoMenuItemTitle ?? "Redo") {
                    session.controller.mixerAdjustmentEditing(false)
                    session.controller.mixerUndoManager?.redo(); session.refresh()
                }.keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(session.controller.mixerUndoManager?.canRedo != true)
            }
        }
    }
}
