import SwiftUI

nonisolated enum AudioClipPreviewPlan {
    static func requiresRender(for settings: AudioClipSettings?) -> Bool {
        settings?.isNeutral == false
    }
}

struct SourceClipEditorView: View {
    @ObservedObject var controller: ProjectController
    let asset: MediaAssetRecord
    private var currentAsset: MediaAssetRecord { controller.asset(for: editSelection) ?? asset }
    @Environment(\.openWindow) private var openWindow
    let editSelection: EditorSelection
    let initialSegments: [SourceSegment]
    @ObservedObject var commandContext: ClipPlacementCommandContext

    @StateObject private var viewModel = VideoPlayerViewModel()
    @State private var loadedAssetID: UUID?
    @State private var preparationTask: Task<Void, Never>?
    @State private var cacheOwnerID = UUID()
    @State private var placementFocusReturn: PlacementAction?
    @State private var audioPreviewTask: Task<Void, Never>?
    @State private var audioPreviewProgress: Double?
    @State private var audioPreviewErrorMessage: String?
    @State private var newTrackKind: NewTrackSourceKind?
    @AccessibilityFocusState private var focusedPlacementControl: PlacementAction?
    @AccessibilityFocusState private var newTrackMenuFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.resolveURL(for: currentAsset) == nil {
                Text("This media file is offline. Relink it before editing.")
                    .padding()
            } else {
                ContentView(
                    viewModel: viewModel,
                    allowsFileOpening: false,
                    editorHeading: ClipEditorMediaKind.name(hasVideo: currentAsset.hasVideo)
                )

                if commandContext.audioSettings != nil {
                    AudioClipControlsView(commandContext: commandContext)
                        .disabled(viewModel.isExporting || viewModel.isPresentingExportPanel)
                        .padding(.horizontal, 20)
                }
                if let audioPreviewProgress {
                    ProgressView("Updating Clip Preview", value: audioPreviewProgress).padding(.horizontal, 20)
                }

                if commandContext.isTimelineEntry, currentAsset.generator != nil {
                    Button("Edit Generator…") {
                        controller.requestGenerator(editing: editSelection)
                        if let id = controller.generatorRequestID { openWindow(id: "generator", value: id) }
                    }.padding(.horizontal, 20).disabled(commandContext.hasUncommittedChanges)
                }
                if commandContext.isTimelineEntry {
                    ScrollView { ClipFiltersView(context: commandContext).padding(.horizontal, 20) }
                        .disabled(viewModel.isExporting || viewModel.isPresentingExportPanel)
                        .frame(maxHeight: 250)
                }

                ClipExportControlsView(viewModel: viewModel)
                    .padding(.horizontal, 20)

                placementControls
                    .disabled(viewModel.isExporting || viewModel.isPresentingExportPanel)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
        }
        .onAppear {
            if let cacheKey = currentAsset.proxyCacheKey {
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
        .onChange(of: controller.project) { commandContext.refreshCommittedEffects() }
        .onChange(of: currentAsset.id) {
            audioPreviewTask?.cancel()
            preparationTask?.cancel()
            commandContext.acceptExternalGeneratorUpdate()
            viewModel.closeMedia()
            loadIfNeeded()
        }
        .onChange(of: viewModel.placementSourceSegments) { _, segments in
            guard loadedAssetID == currentAsset.id else { return }
            commandContext.setSegments(segments)
        }
        .onChange(of: viewModel.hasMedia) {
            guard viewModel.hasMedia else { return }
            scheduleAudioPreview(for: commandContext.audioSettings, debounce: false)
        }
        .onChange(of: commandContext.filters) { scheduleAudioPreview(for: commandContext.audioSettings) }
        .onChange(of: viewModel.audioPreviewSegments) { scheduleAudioPreview(for: commandContext.audioSettings) }
        .onChange(of: commandContext.audioSettings) { _, settings in
            scheduleAudioPreview(for: settings)
        }
        .sheet(item: $commandContext.trackPlacementAction, onDismiss: restorePlacementControlFocus) { action in
            let audioOnly = commandContext.trackPlacementIsAudioOnly
            AddToTrackView(
                commandContext: commandContext,
                action: action,
                heading: audioOnly ? "Add Audio Only to Track" : "Add to Track",
                audioOnly: audioOnly,
                tracks: compatibleTracks(audioOnly: audioOnly),
                canCreateAudioTrack: currentAsset.hasAudio,
                canCreateVideoTrack: currentAsset.hasVideo && !audioOnly,
                addToTrack: { trackID in
                    guard commandContext.place(action, onTrack: trackID) != nil else { return }
                    commandContext.dismissTrackPlacement()
                },
                createTrackAndAdd: { kind, name in
                    createAndPlace(kind: kind, name: name, action: action)
                },
                cancel: commandContext.dismissTrackPlacement
            )
            .onAppear { placementFocusReturn = action }
        }
        .sheet(item: $newTrackKind, onDismiss: restoreNewTrackMenuFocus) { kind in
            NewTrackFromSourceView(
                kind: kind,
                suggestedTrackName: kind.suggestedTrackName(
                    sourceName: currentAsset.name,
                    sourceHasVideo: currentAsset.hasVideo
                ),
                presentedError: $commandContext.presentedError,
                create: { name in
                    commandContext.createTrackAndPlace(
                        .append,
                        kind: kind.trackKind,
                        name: name
                    ) != nil
                },
                close: { newTrackKind = nil }
            )
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
        .alert("Clip Preview Could Not Be Updated", isPresented: Binding(
            get: { audioPreviewErrorMessage != nil },
            set: { if !$0 { audioPreviewErrorMessage = nil } }
        )) {
            Button("OK") { audioPreviewErrorMessage = nil }
        } message: {
            Text(audioPreviewErrorMessage ?? "The clip preview could not be updated.")
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
            if currentAsset.hasVideo {
                Menu("Insert on Top") {
                    Button("With Source Audio") { place(.cutawaySourceAudio) }
                        .keyboardShortcut("q", modifiers: [])
                    Button("Over Primary Audio") { place(.cutawayPrimaryAudio) }
                        .keyboardShortcut("q", modifiers: [.option])
                }
                .disabled(!commandContext.canPlace)
            }
            if currentAsset.hasVideo && currentAsset.hasAudio {
                Menu("Audio Only") {
                    Button("Append Audio to Track…") {
                        commandContext.requestAudioOnlyTrackPlacement(.append)
                    }
                    Button("Insert Audio at Playhead on Track…") {
                        commandContext.requestAudioOnlyTrackPlacement(.insert)
                    }
                    Button("Insert and Overwrite Audio on Track…") {
                        commandContext.requestAudioOnlyTrackPlacement(.replaceRemainder)
                    }
                }
                .disabled(!commandContext.canPlace)
            }
            Menu("New Track") {
                ForEach(NewTrackSourceKind.availableKinds(
                    hasVideo: currentAsset.hasVideo,
                    hasAudio: currentAsset.hasAudio
                )) { kind in
                    Button(kind.commandTitle) { newTrackKind = kind }
                }
            }
            .disabled(!commandContext.canPlace)
            .accessibilityFocused($newTrackMenuFocused)
        }
    }

    private func loadIfNeeded() {
        guard loadedAssetID != currentAsset.id, let url = controller.resolveURL(for: currentAsset) else { return }
        loadedAssetID = currentAsset.id
        commandContext.setSegments(controller.segments(for: editSelection) ?? initialSegments)
        let opening = ClipEditorOpeningConfiguration.make(
            segments: controller.segments(for: editSelection) ?? initialSegments,
            sourceDuration: currentAsset.duration
        )
        preparationTask = Task { @MainActor in
            do {
                let source = try await controller.preparedMediaSource(for: currentAsset)
                try Task.checkCancellation()
                if let cacheKey = controller.project.asset(id: currentAsset.id)?.proxyCacheKey {
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

    private func compatibleTracks(audioOnly: Bool) -> [TimelineTrack] {
        controller.project.tracks.filter { track in
            if audioOnly { return track.kind == .audio && currentAsset.hasAudio }
            return (track.kind == .video && currentAsset.hasVideo) || (track.kind == .audio && currentAsset.hasAudio)
        }
    }

    private func createAndPlace(
        kind: TimelineTrackKind,
        name: String,
        action: PlacementAction
    ) {
        guard commandContext.createTrackAndPlace(action, kind: kind, name: name) != nil else { return }
        commandContext.dismissTrackPlacement()
    }

    private func scheduleAudioPreview(
        for settings: AudioClipSettings?,
        debounce: Bool = true
    ) {
        audioPreviewTask?.cancel()
        audioPreviewTask = nil
        audioPreviewErrorMessage = nil
        guard viewModel.hasMedia else { return }
        let filters = commandContext.filters
        let audio = commandContext.audioSettings != nil
        guard AudioClipPreviewPlan.requiresRender(for: settings) || filters.contains(where: { $0.enabled }) else {
            audioPreviewProgress = nil
            viewModel.restoreUnprocessedAudioPreview()
            commandContext.effectsReady = true
            viewModel.clipEffectsReady = true
            return
        }
        guard let sourceURL = controller.resolveURL(for: currentAsset),
              !viewModel.audioPreviewSegments.isEmpty else { return }
        let segments = viewModel.audioPreviewSegments
        audioPreviewProgress = 0
        commandContext.effectsReady = false
        viewModel.clipEffectsReady = false
        audioPreviewTask = Task { @MainActor in
            var generatedURL: URL?
            do {
                if debounce {
                    try await Task.sleep(for: .milliseconds(250))
                }
                let outputURL = try await ClipFilterRenderer.render(
                    source: sourceURL, filters: filters, audio: audio,
                    duration: segments.reduce(0) { $0 + $1.duration.seconds },
                    segments: segments, audioSettings: settings
                ) { progress in
                    audioPreviewProgress = progress
                }
                generatedURL = outputURL
                try Task.checkCancellation()
                try await viewModel.applyFilteredPreview(at: outputURL, audio: audio)
                commandContext.effectsReady = true
                viewModel.clipEffectsReady = true
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

    private func restoreNewTrackMenuFocus() {
        newTrackMenuFocused = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            newTrackMenuFocused = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            newTrackMenuFocused = true
        }
    }
}

private struct AddToTrackView: View {
    @ObservedObject var commandContext: ClipPlacementCommandContext
    let action: PlacementAction
    let heading: String
    let audioOnly: Bool
    let tracks: [TimelineTrack]
    let canCreateAudioTrack: Bool
    let canCreateVideoTrack: Bool
    let addToTrack: (UUID) -> Void
    let createTrackAndAdd: (TimelineTrackKind, String) -> Void
    let cancel: () -> Void

    @State private var selectedTrackID: UUID?
    @State private var newTrackName = ""
    @AccessibilityFocusState private var trackPickerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(heading)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Picker("Track", selection: trackBinding) {
                ForEach(tracks) { track in
                    Text(track.name).tag(Optional(track.id))
                }
            }
            .accessibilityFocused($trackPickerFocused)

            Button(action.selectedTrackButtonTitle(audioOnly: audioOnly)) {
                guard let selectedTrackID else { return }
                addToTrack(selectedTrackID)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedTrackID == nil)

            Divider()

            LabeledContent("New Track Name") {
                TextField("New Track Name", text: $newTrackName)
                    .labelsHidden()
            }

            HStack {
                Button("Create Audio Track and \(action.newTrackButtonTitle(audioOnly: audioOnly))") {
                    createTrackAndAdd(.audio, newTrackName)
                }
                    .disabled(!canCreateAudioTrack)
                if !audioOnly {
                    Button("Create Video Track and \(action.newTrackButtonTitle(audioOnly: false))") {
                        createTrackAndAdd(.video, newTrackName)
                    }
                        .disabled(!canCreateVideoTrack)
                }
            }
            .disabled(newTrackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("Cancel", role: .cancel, action: cancel)
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { selectedTrackID = tracks.first?.id }
        .alert(item: $commandContext.presentedError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var trackBinding: Binding<UUID?> {
        Binding(
            get: { selectedTrackID },
            set: { newValue in
                selectedTrackID = newValue
                restoreTrackPickerFocus()
            }
        )
    }

    private func restoreTrackPickerFocus() {
        trackPickerFocused = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            trackPickerFocused = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            trackPickerFocused = true
        }
    }
}

private extension PlacementAction {
    func selectedTrackButtonTitle(audioOnly: Bool) -> String {
        if audioOnly {
            switch self {
            case .append: return "Append Audio to Selected Track"
            case .insert: return "Insert Audio on Selected Track"
            case .replaceRemainder: return "Insert and Overwrite Audio on Selected Track"
            case .cutawaySourceAudio, .cutawayPrimaryAudio: return "Add Audio to Selected Track"
            }
        }
        switch self {
        case .append: return "Append to Selected Track"
        case .insert: return "Insert on Selected Track"
        case .replaceRemainder: return "Insert and Overwrite on Selected Track"
        case .cutawaySourceAudio, .cutawayPrimaryAudio: return "Add to Selected Track"
        }
    }

    func newTrackButtonTitle(audioOnly: Bool) -> String {
        if audioOnly {
            switch self {
            case .append: return "Append Audio"
            case .insert: return "Insert Audio"
            case .replaceRemainder: return "Insert and Overwrite Audio"
            case .cutawaySourceAudio, .cutawayPrimaryAudio: return "Add Audio"
            }
        }
        switch self {
        case .append: return "Append"
        case .insert: return "Insert"
        case .replaceRemainder: return "Insert and Overwrite"
        case .cutawaySourceAudio, .cutawayPrimaryAudio: return "Add"
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
                }
                Button("Reset Gain") { commandContext.resetAudioSettings() }
            }
            .padding(.top, 4)
        } label: {
            Text("Audio").accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Audio")
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
