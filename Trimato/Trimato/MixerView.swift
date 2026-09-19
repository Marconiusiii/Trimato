import AVFoundation
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
    @Published private(set) var waveformRevision = 0
    private var waveformProject: TrimatoProject?
    private var observation: AnyCancellable?
    private let fromTimeline: Bool
    private let origin: TimelineElementSelection?

    init(controller: ProjectController, player: ProjectPlayerViewModel) {
        self.controller = controller; self.player = player
        if NSWorkspace.shared.isVoiceOverEnabled, let window = controller.projectSaveCoordinator?.attachedWindow {
            if case .timeline = WorkspaceVoiceOverCommandFocus.forWindow(window).owner { fromTimeline = true }
            else { fromTimeline = false }
        } else {
            fromTimeline = controller.timelineHasKeyboardFocus || TimelineKeyboardFocus.isInTimeline
        }
        origin = controller.selectedTimelineClip.map { .clip($0.id) }
        refresh()
        selectedID = tracks.contains(where: { $0.id == controller.activeTimelineTrackID })
            ? controller.activeTimelineTrackID : tracks.first?.id
        observation = controller.document.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
    }
    var selected: MixerTrack? { tracks.first { $0.id == selectedID } }
    func refresh() {
        if waveformProject != controller.project {
            waveformProject = controller.project
            waveformRevision &+= 1
        }
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
        waveformRevision &+= 1
        player.updateMix(project: controller.project, solo: soloIDs)
    }
    func reset() {
        guard let selectedID else { return }
        if soloIDs.remove(selectedID) != nil { waveformRevision &+= 1 }
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
        ScrollView {
            controls.fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 440, idealWidth: 440, minHeight: 620, idealHeight: 700)
        .background(EditorTheme.controlSurface)
        .blocksEditingDuringQuit()
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mixer").font(EditorTheme.dialogTitle).accessibilityAddTraits(.isHeader)
            MixerPlaybackControls(player: player, waveformRevision: session.waveformRevision, play: session.togglePlayback)
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
                HStack {
                    Toggle("Mute", isOn: Binding(get: { session.selected?.muted ?? false }, set: session.mute))
                    Toggle("Solo", isOn: Binding(get: { session.selectedID.map { session.soloIDs.contains($0) } ?? false }, set: session.solo))
                }
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
            HStack {
                ContextualHelpButton(topic: .mixer)
                Spacer()
            }
        }
        .padding(EditorTheme.dialogPadding)
        .frame(minWidth: 440, idealWidth: 440)
        .background(EditorTheme.controlSurface)
        .blocksEditingDuringQuit()
    }
}

// The surrounding controls observe semantic changes, never the live clock.
@MainActor
final class MixerPlaybackPresentation: ObservableObject {
    struct State: Equatable {
        var error: String?
        var ready: Bool
        var playing: Bool
        var showingFrames: Bool
        var timecode: String
        var duration: Double
        var step: Double
        var itemID: ObjectIdentifier?

        init(player: ProjectPlayerViewModel) {
            error = player.errorMessage
            ready = player.canControlPlayback
            playing = player.isPlaying
            showingFrames = player.showingFrames
            timecode = player.accessibilityTimecodeLabel
            duration = player.duration.seconds
            step = player.playbackFractionStep
            itemID = player.player.currentItem.map(ObjectIdentifier.init)
        }
    }

    @Published private(set) var state: State
    private var observation: AnyCancellable?

    init(player: ProjectPlayerViewModel) {
        state = State(player: player)
        observation = player.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self, weak player] _ in
                guard let self, let player else { return }
                let next = State(player: player)
                if self.state != next { self.state = next }
            }
    }
}

private struct MixerLivePlayhead: View {
    @ObservedObject var player: ProjectPlayerViewModel
    @ObservedObject private var clock: ProjectPlaybackClock
    init(player: ProjectPlayerViewModel) {
        self.player = player
        clock = player.playbackClock
    }
    var body: some View {
        MixerPlayheadSlider(value: Binding(get: {
            player.duration.isPositive ? clock.time.seconds / player.duration.seconds : 0
        }, set: { player.seek(toFraction: $0) }),
            step: player.playbackFractionStep, timecode: player.accessibilityTimecodeLabel,
            ready: player.canControlPlayback, playing: player.isPlaying)
    }
}

private struct MixerWaveform: View {
    let player: ProjectPlayerViewModel
    let revision: Int
    let playing: Bool
    let itemID: ObjectIdentifier?
    @State private var samples: [Float] = []
    @State private var loading = false
    @State private var completed: Request?
    private struct Request: Equatable {
        let revision: Int
        let itemID: ObjectIdentifier?
        let playing: Bool
    }
    var body: some View {
        MixerWaveformDisplay(clock: player.playbackClock, samples: samples,
            duration: player.duration.seconds, loading: loading)
            .frame(minHeight: 80, idealHeight: 120, maxHeight: 160)
            .task(id: Request(revision: revision, itemID: itemID, playing: playing)) {
                let request = Request(revision: revision, itemID: itemID, playing: false)
                guard !playing, completed != request, itemID != nil else { return }
                loading = true
                defer { loading = false }
                do {
                    // Coalesce rapid mix edits and yield to actual playback.
                    try await Task.sleep(for: .milliseconds(300))
                    guard let (asset, mix) = try player.waveformInput() else { return }
                    let waveform = try await AudioWaveformAnalyzer.analyzeProject(asset: asset, audioMix: mix)
                    try Task.checkCancellation()
                    samples = waveform.samples
                    completed = request
                } catch is CancellationError {
                    return
                } catch {
                    samples = []
                }
            }
    }
}

private struct MixerWaveformDisplay: View {
    @ObservedObject var clock: ProjectPlaybackClock
    let samples: [Float]
    let duration: Double
    let loading: Bool
    var body: some View {
        AudioWaveformView(samples: samples, playbackFraction: duration > 0 ? clock.time.seconds / duration : 0,
            isLoading: loading)
    }
}

private struct MixerPlaybackControls: View {
    let player: ProjectPlayerViewModel
    @StateObject private var presentation: MixerPlaybackPresentation
    let waveformRevision: Int
    let play: () -> Void
    @AppStorage(AppPreferenceKey.accentColor) private var accentChoice = EditorAccent.teal
    @StateObject private var keyboard = SettingsSliderKeyboard(identifier: "trimato.mixer.playhead")
    init(player: ProjectPlayerViewModel, waveformRevision: Int, play: @escaping () -> Void) {
        self.waveformRevision = waveformRevision
        self.player = player
        self.play = play
        _presentation = StateObject(wrappedValue: MixerPlaybackPresentation(player: player))
    }

    var body: some View {
        VStack(spacing: 10) {
            if let message = presentation.state.error {
                Text(message).textSelection(.enabled)
            }
            MixerWaveform(player: player, revision: waveformRevision, playing: presentation.state.playing,
                itemID: presentation.state.itemID)
            MixerLivePlayhead(player: player)
                .tint(EditorTheme.playhead)
                .onAppear { keyboard.start() }
                .onDisappear { keyboard.stop() }
            playbackControls
        }
        .disabled(!presentation.state.ready)
    }

    private var playbackControls: some View {
        GroupBox {
            VStack(spacing: 8) {
                Button { player.toggleTimecodeDisplay() } label: {
                    VStack(spacing: 2) {
                        ProjectLiveTimecode(clock: player.playbackClock, showingFrames: presentation.state.showingFrames)
                            .font(.system(.title, design: .monospaced).weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(EditorTheme.accent(for: accentChoice))
                        Text(presentation.state.showingFrames ? "Frames" : "Timecode")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(EditorTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Project timecode")
                .accessibilityValue(presentation.state.timecode)
                HStack(spacing: EditorTheme.actionSpacing) {
                    transportButton("Step backward one frame", image: "backward.frame.fill", action: player.stepBackward)
                    transportButton("Skip back 10 seconds", image: "gobackward.10", action: player.seekBackward)
                    transportButton(presentation.state.playing ? "Pause" : "Play", image: presentation.state.playing ? "pause.fill" : "play.fill", primary: true, action: play)
                    transportButton("Skip forward 10 seconds", image: "goforward.10", action: player.seekForward)
                    transportButton("Step forward one frame", image: "forward.frame.fill", action: player.stepForward)
                }
                .foregroundStyle(EditorTheme.accent(for: accentChoice))
                HStack {
                    Button("Go to Beginning", action: player.goToStart)
                    Button("Go to End", action: player.goToEnd)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Playback").accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback")
        .accessibilityIdentifier("trimato.mixer.playback")
    }

    private func transportButton(_ title: String, image: String, primary: Bool = false,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: primary ? 22 : 17, weight: primary ? .semibold : .medium))
                .frame(width: primary ? 32 : 28, height: 24)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(title)
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
