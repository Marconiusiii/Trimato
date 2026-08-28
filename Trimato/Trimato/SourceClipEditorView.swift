import SwiftUI

struct SourceClipEditorView: View {
    @ObservedObject var controller: ProjectController
    let asset: MediaAssetRecord
    let editSelection: EditorSelection
    let initialSegments: [SourceSegment]
    @ObservedObject var commandContext: ClipPlacementCommandContext

    @StateObject private var viewModel = VideoPlayerViewModel()
    @State private var loadedAssetID: UUID?
    @State private var preparationTask: Task<Void, Never>?
    @State private var cacheOwnerID = UUID()
    @State private var selectedTrackID: UUID?
    @State private var placementFocusReturn: PlacementAction?
    @AccessibilityFocusState private var focusedPlacementControl: PlacementAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.resolveURL(for: asset) == nil {
                Text("This media file is offline. Relink it before editing.")
            } else {
                ContentView(viewModel: viewModel, allowsFileOpening: false)

                if commandContext.audioSettings != nil {
                    AudioClipControlsView(commandContext: commandContext)
                        .padding(.horizontal, 10)
                }

                HStack {
                    if commandContext.isTimelineEntry {
                        Button("Update Clip") { commandContext.performUpdate() }
                            .keyboardShortcut("u", modifiers: .command)
                            .disabled(!commandContext.canUpdate)
                        Divider()
                    }
                    Button(PlacementAction.append.title) { place(.append) }
                        .keyboardShortcut("e", modifiers: [])
                        .disabled(!commandContext.canPlace)
                        .accessibilityFocused($focusedPlacementControl, equals: .append)
                    Button(PlacementAction.insert.title) { place(.insert) }
                        .keyboardShortcut("w", modifiers: [])
                        .disabled(!commandContext.canPlace)
                        .accessibilityFocused($focusedPlacementControl, equals: .insert)
                    Button(PlacementAction.replaceRemainder.title) { place(.replaceRemainder) }
                        .keyboardShortcut("d", modifiers: [])
                        .disabled(!commandContext.canPlace)
                        .accessibilityFocused($focusedPlacementControl, equals: .replaceRemainder)
                    Menu("Insert on Top") {
                        Button("With Source Audio") { place(.cutawaySourceAudio) }
                            .keyboardShortcut("q", modifiers: [])
                        Button("Over Primary Audio") { place(.cutawayPrimaryAudio) }
                            .keyboardShortcut("q", modifiers: [.option])
                    }
                    .disabled(!commandContext.canPlace || !asset.hasVideo)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        .onAppear {
            if let cacheKey = asset.proxyCacheKey {
                let owner = cacheOwnerID
                Task {
                    await MediaCacheManager.shared.updateProtectedKeys(owner: owner, keys: [cacheKey])
                }
            }
            viewModel.scopeKeyboardCommands { [weak commandContext] in
                commandContext?.isKeyWindow == true
            }
            loadIfNeeded()
            restorePlacementControlFocus(to: .append)
        }
        .onChange(of: viewModel.placementSourceSegments) { segments in
            guard loadedAssetID == asset.id else { return }
            commandContext.setSegments(segments)
        }
        .onChange(of: commandContext.focusRequest) {
            restorePlacementControlFocus(to: .append)
        }
        .sheet(item: $commandContext.trackPlacementAction, onDismiss: restorePlacementControlFocus) { action in
            VStack(alignment: .leading, spacing: 16) {
                Text(action.title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Form {
                    Picker("Track", selection: $selectedTrackID) {
                        ForEach(compatibleTracks) { track in
                            Text(track.name).tag(Optional(track.id))
                        }
                    }
                    Section("Create a Track") {
                        Button("New Audio Track") { createAndPlace(kind: .audio, action: action) }
                            .disabled(!asset.hasAudio)
                        Button("New Video Track") { createAndPlace(kind: .video, action: action) }
                            .disabled(!asset.hasVideo)
                    }
                }
                .formStyle(.grouped)
                .frame(height: 190)
                HStack {
                    Button("Cancel", role: .cancel) { commandContext.trackPlacementAction = nil }
                    Button("Place") {
                        guard let selectedTrackID else { return }
                        controller.place(action, editing: editSelection, segments: commandContext.segments, onTrack: selectedTrackID)
                        commandContext.trackPlacementAction = nil
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedTrackID == nil)
                }
            }
            .padding(20)
            .frame(width: 420)
            .onAppear {
                placementFocusReturn = action
                selectedTrackID = compatibleTracks.first?.id
            }
        }
        .onDisappear {
            preparationTask?.cancel()
            preparationTask = nil
            viewModel.closeMedia()
            let owner = cacheOwnerID
            Task { await MediaCacheManager.shared.releaseProtectedKeys(owner: owner) }
        }
    }

    private func loadIfNeeded() {
        guard loadedAssetID != asset.id, let url = controller.resolveURL(for: asset) else { return }
        loadedAssetID = asset.id
        commandContext.setSegments(initialSegments)
        let opening = ClipEditorOpeningConfiguration.make(
            segments: initialSegments,
            sourceDuration: asset.duration
        )
        preparationTask = Task { @MainActor in
            do {
                let source = try await controller.preparedMediaSource(for: asset)
                try Task.checkCancellation()
                if let cacheKey = controller.project.asset(id: asset.id)?.proxyCacheKey {
                    await MediaCacheManager.shared.updateProtectedKeys(
                        owner: cacheOwnerID,
                        keys: [cacheKey]
                    )
                }
                viewModel.load(
                    url: url,
                    sourceSegments: opening.playbackSegments,
                    preparedSource: source,
                    initialInMarker: opening.inMarker,
                    initialOutMarker: opening.outMarker
                )
            } catch is CancellationError {
                return
            } catch {
                loadedAssetID = nil
                controller.presentedError = ProjectPresentedError(
                    title: "Clip Preparation Failed",
                    message: error.localizedDescription
                )
            }
            preparationTask = nil
        }
    }

    private func place(_ placement: PlacementAction) {
        commandContext.place(placement)
    }

    private var compatibleTracks: [TimelineTrack] {
        controller.project.tracks.filter { track in
            (track.kind == .video && asset.hasVideo) || (track.kind == .audio && asset.hasAudio)
        }
    }

    private func createAndPlace(kind: TimelineTrackKind, action: PlacementAction) {
        controller.addTrack(kind: kind, name: nil)
        guard let trackID = controller.activeTimelineTrackID else { return }
        controller.place(action, editing: editSelection, segments: commandContext.segments, onTrack: trackID)
        commandContext.trackPlacementAction = nil
    }

    private func restorePlacementControlFocus() {
        guard let target = placementFocusReturn else { return }
        placementFocusReturn = nil
        restorePlacementControlFocus(to: target)
    }

    private func restorePlacementControlFocus(to target: PlacementAction) {
        focusedPlacementControl = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            focusedPlacementControl = target
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            focusedPlacementControl = target
        }
    }
}

private struct AudioClipControlsView: View {
    @ObservedObject var commandContext: ClipPlacementCommandContext

    var body: some View {
        GroupBox("Audio") {
            VStack(alignment: .leading, spacing: 10) {
                valueField("Gain", value: binding(\.gainDecibels), suffix: "dB")
                valueField("Low EQ", value: binding(\.lowGainDecibels), suffix: "dB")
                valueField("Mid EQ", value: binding(\.midGainDecibels), suffix: "dB")
                valueField("High EQ", value: binding(\.highGainDecibels), suffix: "dB")
                Toggle("High-pass filter", isOn: binding(\.highPassEnabled))
                if commandContext.audioSettings?.highPassEnabled == true {
                    valueField("High-pass frequency", value: binding(\.highPassFrequency), suffix: "Hz")
                }
                Toggle("Low-pass filter", isOn: binding(\.lowPassEnabled))
                if commandContext.audioSettings?.lowPassEnabled == true {
                    valueField("Low-pass frequency", value: binding(\.lowPassFrequency), suffix: "Hz")
                }
                Button("Reset Audio") { commandContext.resetAudioSettings() }
                    .disabled(commandContext.audioSettings?.isNeutral != false)
            }
            .padding(.top, 4)
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AudioClipSettings, T>) -> Binding<T> {
        Binding(
            get: { commandContext.audioSettings?[keyPath: keyPath] ?? AudioClipSettings.neutral[keyPath: keyPath] },
            set: { value in
                var settings = commandContext.audioSettings ?? .neutral
                settings[keyPath: keyPath] = value
                commandContext.audioSettings = settings
            }
        )
    }

    private func valueField(_ label: String, value: Binding<Double>, suffix: String) -> some View {
        LabeledContent(label) {
            HStack {
                TextField(label, value: value, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                Text(suffix).foregroundStyle(.secondary)
            }
        }
    }
}
