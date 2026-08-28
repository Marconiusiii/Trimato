import SwiftUI

nonisolated enum AudioClipPreviewPlan {
    static func requiresRender(for settings: AudioClipSettings?) -> Bool {
        settings?.isNeutral == false
    }
}

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
    @State private var audioPreviewTask: Task<Void, Never>?
    @State private var audioPreviewProgress: Double?
    @State private var audioPreviewErrorMessage: String?
    @AccessibilityFocusState private var focusedPlacementControl: PlacementAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.resolveURL(for: asset) == nil {
                Text("This media file is offline. Relink it before editing.")
                    .padding()
            } else {
                ContentView(
                    viewModel: viewModel,
                    allowsFileOpening: false,
                    editorHeading: ClipEditorMediaKind.name(hasVideo: asset.hasVideo),
                    accessibilityFocusRequest: commandContext.focusRequest
                )

                if commandContext.audioSettings != nil {
                    AudioClipControlsView(commandContext: commandContext)
                        .padding(.horizontal, 20)
                    if let audioPreviewProgress {
                        ProgressView(value: audioPreviewProgress) {
                            Text("Updating Audio Preview")
                        }
                        .padding(.horizontal, 20)
                    }
                }

                ClipExportControlsView(viewModel: viewModel)
                    .padding(.horizontal, 20)

                placementControls
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
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
        }
        .onChange(of: viewModel.placementSourceSegments) { _, segments in
            guard loadedAssetID == asset.id else { return }
            commandContext.setSegments(segments)
        }
        .onChange(of: viewModel.hasMedia) {
            guard viewModel.hasMedia else { return }
            scheduleAudioPreview(for: commandContext.audioSettings, debounce: false)
        }
        .onChange(of: commandContext.audioSettings) { _, settings in
            scheduleAudioPreview(for: settings)
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
                        commandContext.place(action, onTrack: selectedTrackID)
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
            audioPreviewTask?.cancel()
            audioPreviewTask = nil
            viewModel.closeMedia()
            let owner = cacheOwnerID
            Task { await MediaCacheManager.shared.releaseProtectedKeys(owner: owner) }
        }
        .alert("Audio Preview Could Not Be Updated", isPresented: Binding(
            get: { audioPreviewErrorMessage != nil },
            set: { if !$0 { audioPreviewErrorMessage = nil } }
        )) {
            Button("OK") { audioPreviewErrorMessage = nil }
        } message: {
            Text(audioPreviewErrorMessage ?? "The audio preview could not be updated.")
        }
    }

    @ViewBuilder
    private var placementControls: some View {
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
            if asset.hasVideo {
                Menu("Insert on Top") {
                    Button("With Source Audio") { place(.cutawaySourceAudio) }
                        .keyboardShortcut("q", modifiers: [])
                    Button("Over Primary Audio") { place(.cutawayPrimaryAudio) }
                        .keyboardShortcut("q", modifiers: [.option])
                }
                .disabled(!commandContext.canPlace)
            }
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
        commandContext.place(action, onTrack: trackID)
        commandContext.trackPlacementAction = nil
    }

    private func scheduleAudioPreview(
        for settings: AudioClipSettings?,
        debounce: Bool = true
    ) {
        audioPreviewTask?.cancel()
        audioPreviewTask = nil
        audioPreviewErrorMessage = nil
        guard commandContext.audioSettings != nil, viewModel.hasMedia else { return }
        guard AudioClipPreviewPlan.requiresRender(for: settings), let settings else {
            audioPreviewProgress = nil
            viewModel.restoreUnprocessedAudioPreview()
            return
        }
        guard let sourceURL = controller.resolveURL(for: asset),
              !viewModel.audioPreviewSegments.isEmpty else { return }
        let segments = viewModel.audioPreviewSegments
        audioPreviewProgress = 0
        audioPreviewTask = Task { @MainActor in
            var generatedURL: URL?
            do {
                if debounce {
                    try await Task.sleep(for: .milliseconds(250))
                }
                let outputURL = try await FFmpegTimelineEffectRenderer.renderAudio(
                    sourceURL: sourceURL,
                    segments: segments,
                    settings: settings
                ) { progress in
                    audioPreviewProgress = progress
                }
                generatedURL = outputURL
                try Task.checkCancellation()
                try await viewModel.applyAudioPreview(at: outputURL)
                generatedURL = nil
                audioPreviewProgress = nil
                audioPreviewTask = nil
            } catch is CancellationError {
                if let generatedURL {
                    try? FileManager.default.removeItem(at: generatedURL)
                }
            } catch {
                if let generatedURL {
                    try? FileManager.default.removeItem(at: generatedURL)
                }
                audioPreviewProgress = nil
                audioPreviewTask = nil
                audioPreviewErrorMessage = error.localizedDescription
            }
        }
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
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    audioSlider(
                        "Gain",
                        value: binding(\.gainDecibels),
                        range: AudioClipControlSpecification.gainRange,
                        step: AudioClipControlSpecification.decibelStep,
                        identifier: "gain"
                    )
                    audioSlider(
                        "Low EQ",
                        value: binding(\.lowGainDecibels),
                        range: AudioClipControlSpecification.equalizerRange,
                        step: AudioClipControlSpecification.decibelStep,
                        identifier: "low-eq"
                    )
                    audioSlider(
                        "Mid EQ",
                        value: binding(\.midGainDecibels),
                        range: AudioClipControlSpecification.equalizerRange,
                        step: AudioClipControlSpecification.decibelStep,
                        identifier: "mid-eq"
                    )
                    audioSlider(
                        "High EQ",
                        value: binding(\.highGainDecibels),
                        range: AudioClipControlSpecification.equalizerRange,
                        step: AudioClipControlSpecification.decibelStep,
                        identifier: "high-eq"
                    )
                }

                HStack(spacing: 18) {
                    Toggle("Reduce low rumble", isOn: binding(\.highPassEnabled))
                    Toggle("Reduce high-frequency hiss", isOn: binding(\.lowPassEnabled))
                    Spacer()
                    Button("Reset Audio") { commandContext.resetAudioSettings() }
                        .disabled(commandContext.audioSettings?.isNeutral != false)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Audio Filters").accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Audio Filters")
        .accessibilityIdentifier("trimato.clip-editor.audio-filters")
    }

    private func audioSlider(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        identifier: String
    ) -> some View {
        HStack(spacing: 6) {
            Slider(value: value, in: range, step: step) {
                Text(label)
            }
            .accessibilityValue(AudioClipControlSpecification.spokenDecibels(value.wrappedValue))
            .accessibilityIdentifier(ClipEditorAccessibilityIdentifier.audioSlider(identifier))

            Text(AudioClipControlSpecification.visibleDecibels(value.wrappedValue))
                .monospacedDigit()
                .frame(minWidth: 44, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
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
}

nonisolated enum AudioClipControlSpecification {
    static let gainRange = -60.0...12.0
    static let equalizerRange = -12.0...12.0
    static let decibelStep = 1.0

    static func visibleDecibels(_ value: Double) -> String {
        "\(Int(value.rounded())) dB"
    }

    static func spokenDecibels(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return "\(rounded) decibel\(abs(rounded) == 1 ? "" : "s")"
    }
}
