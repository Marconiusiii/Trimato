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
    @State private var preparingSource = false
    @State private var preparationID = UUID()
    @State private var preparationTask: Task<Void, Never>?
    @State private var cacheOwnerID = UUID()
    @StateObject private var preview = ClipPreviewCoordinator()
    @State private var addingFilter = false
    @State private var pendingFilter: ClipFilter?
    @State private var selectedTab = "Markers"
    @State private var newTrackKind: NewTrackSourceKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.resolveURL(for: currentAsset) == nil {
                Text("This media file is offline. Relink it before editing.")
                    .padding()
            } else {
                ContentView(
                    viewModel: viewModel,
                    allowsFileOpening: false,
                    editorHeading: ClipEditorMediaKind.name(hasVideo: currentAsset.hasVideo),
                    compact: true,
                    preparation: sourcePreparation,
                    isPreparingClipPreview: preview.state == .preparing
                )

                TabView(selection: $selectedTab) {
                    ClipMarkerControlsView(viewModel: viewModel)
                        .padding(8).tabItem { Text("Markers") }.tag("Markers")
                    if commandContext.audioSettings != nil {
                        AudioClipControlsView(commandContext: commandContext)
                            .padding(8).tabItem { Text("Audio") }.tag("Audio")
                    }
                    if commandContext.isTimelineEntry {
                        ClipFiltersView(context: commandContext)
                            .padding(8).tabItem { Text("Filters") }.tag("Filters")
                    }
                }
                .frame(height: 170)
                .padding(.horizontal, 20)
                .disabled(viewModel.isExporting || viewModel.isPresentingExportPanel)

                if commandContext.isTimelineEntry {
                    HStack {
                        Button("Add Filter…") { addingFilter = true }
                        if currentAsset.generator != nil {
                            Button("Edit Generator…") {
                                controller.requestGenerator(editing: editSelection)
                                if let id = controller.generatorRequestID { openWindow(id: "generator", value: id) }
                            }.disabled(commandContext.hasUncommittedChanges)
                        }
                    }.padding(.horizontal, 20)
                }
                if !preparingSource, loadedAssetID == nil {
                    Button("Retry Clip Preparation", action: loadIfNeeded).padding(.horizontal, 20)
                }
                previewStatus.padding(.horizontal, 20)

                ClipExportControlsView(viewModel: viewModel)
                    .padding(.horizontal, 20)

                placementControls
                    .disabled(viewModel.isExporting || viewModel.isPresentingExportPanel)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
        }
        .operationProgress(preview.state == .preparing ? OperationProgress(
            title: "Updating Clip Preview", progress: preview.progress,
            detail: "Preparing filters and audio. Your previous preview is preserved until this finishes.",
            cancel: preview.cancel, announceCompletion: false
        ) : nil, outcome: previewOutcome)
        .sheet(isPresented: $addingFilter, onDismiss: {
            if let pendingFilter {
                commandContext.filters.append(pendingFilter)
                self.pendingFilter = nil
                selectedTab = "Filters"
            }
        }) {
            AddClipFilterView(audio: commandContext.audioSettings != nil,
                              existing: commandContext.filters.map(\.kind)) { filter in
                pendingFilter = filter
                addingFilter = false
            } cancel: { addingFilter = false }
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
            preview.reset()
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
        .onChange(of: viewModel.isPreparingWaveform) {
            if !viewModel.isPreparingWaveform { scheduleAudioPreview(for: commandContext.audioSettings, debounce: false) }
        }
        .onChange(of: commandContext.filters) { scheduleAudioPreview(for: commandContext.audioSettings) }
        .onChange(of: viewModel.audioPreviewSegments) { scheduleAudioPreview(for: commandContext.audioSettings) }
        .onChange(of: commandContext.audioSettings) { _, settings in
            scheduleAudioPreview(for: settings)
        }
        .sheet(item: $commandContext.trackPlacementAction) { action in
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
        }
        .sheet(item: $newTrackKind) { kind in
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
            preview.reset()
            viewModel.closeMedia()
            let owner = cacheOwnerID
            Task { await MediaCacheManager.shared.releaseProtectedKeys(owner: owner) }
        }
        .alert("Clip Preview Could Not Be Updated", isPresented: Binding(
            get: { preview.errorMessage != nil },
            set: { if !$0 { preview.errorMessage = nil } }
        )) {
            Button("OK") { preview.errorMessage = nil }
        } message: {
            Text(preview.errorMessage ?? "The clip preview could not be updated.")
        }
    }

    private var sourcePreparation: OperationProgress? {
        guard preparingSource else { return nil }
        return OperationProgress(title: "Preparing Clip", detail: "Preparing source media", cancel: {
            preparationTask?.cancel()
            preparationID = UUID()
            preparingSource = false
            loadedAssetID = nil
        })
    }

    @ViewBuilder
    private var placementControls: some View {
        HStack {
            if commandContext.isTimelineEntry {
                Button("Update Clip") { commandContext.performUpdate() }
                    .disabled(!commandContext.canUpdate)
            }
            Menu("Add to Timeline") {
                Button(PlacementAction.append.title) { place(.append) }
                    .disabled(!commandContext.canPlace)
                Button(PlacementAction.insert.title) { place(.insert) }
                    .disabled(!commandContext.canPlace)
                Button(PlacementAction.replaceRemainder.title) { place(.replaceRemainder) }
                    .disabled(!commandContext.canPlace)
                if currentAsset.hasVideo {
                    Menu("Insert on Top") {
                        Button("With Source Audio") { place(.cutawaySourceAudio) }
                        Button("Over Primary Audio") { place(.cutawayPrimaryAudio) }
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
            }.disabled(!commandContext.canPlace)
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
        let requestID = UUID()
        preparationID = requestID
        preparingSource = true
        preparationTask = Task { @MainActor in
            defer {
                if preparationID == requestID {
                    preparingSource = false
                    preparationTask = nil
                }
            }
            do {
                let source = try await controller.preparedMediaSource(for: currentAsset)
                try Task.checkCancellation()
                guard preparationID == requestID else { return }
                if let cacheKey = controller.project.asset(id: currentAsset.id)?.proxyCacheKey {
                    await MediaCacheManager.shared.updateProtectedKeys(
                        owner: cacheOwnerID,
                        keys: [cacheKey]
                    )
                }
                try Task.checkCancellation()
                guard preparationID == requestID else { return }
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
                guard preparationID == requestID else { return }
                loadedAssetID = nil
                controller.presentedError = ProjectPresentedError(
                    title: "Clip Preparation Failed",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func place(_ placement: PlacementAction) {
        commandContext.place(placement)
    }

    private func compatibleTracks(audioOnly: Bool) -> [TimelineTrack] {
        controller.project.orderedTimelineTracks.filter { track in
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

    @ViewBuilder
    private var previewStatus: some View {
        switch preview.state {
        case .ready:
            EmptyView()
        case .preparing:
            EmptyView()
        case .cancelled, .failed:
            VStack(alignment: .leading, spacing: 8) {
                Text(preview.state == .cancelled ? "Clip preview preparation cancelled." : "Clip preview could not be updated.")
                Menu("Preview Recovery") {
                    Button("Retry Clip Preview") {
                        scheduleAudioPreview(for: commandContext.audioSettings, debounce: false, force: true)
                    }
                    Button(preview.lastSuccessfulRequest == nil ? "Remove Filters and Reset Gain" : "Revert Filter and Gain Changes") {
                        revertPreviewChanges()
                    }
                }
            }
        }
    }

    private var previewOutcome: OperationProgressOutcome {
        switch preview.state {
        case .cancelled: .cancelled
        case .failed: .failed
        default: .completed
        }
    }

    private func revertPreviewChanges() {
        let previous = preview.lastSuccessfulRequest
        commandContext.filters = previous?.filters ?? []
        if commandContext.audioSettings != nil {
            commandContext.audioSettings = previous?.audioSettings ?? .neutral
        }
        scheduleAudioPreview(for: commandContext.audioSettings, debounce: false, force: true)
    }

    private func scheduleAudioPreview(
        for settings: AudioClipSettings?,
        debounce: Bool = true,
        force: Bool = false
    ) {
        guard !viewModel.isLoadingMedia, !viewModel.isPreparingWaveform else { return }
        guard viewModel.hasMedia,
              let sourceURL = controller.resolveURL(for: currentAsset),
              !viewModel.audioPreviewSegments.isEmpty else {
            preview.reset()
            commandContext.effectsReady = false
            viewModel.clipEffectsReady = false
            return
        }
        let request = ClipPreviewCoordinator.Request(
            source: sourceURL, filters: commandContext.filters,
            audio: commandContext.audioSettings != nil,
            segments: viewModel.audioPreviewSegments, audioSettings: settings
        )
        preview.update(request, debounce: debounce, force: force, readiness: { ready in
            commandContext.effectsReady = ready
            viewModel.clipEffectsReady = ready
        }, restoreOriginal: {
            viewModel.restoreUnprocessedAudioPreview()
        }, commit: { asset, url, audio in
            viewModel.installFilteredPreview(asset: asset, url: url, audio: audio)
        })
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(heading)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Picker("Track", selection: $selectedTrackID) {
                ForEach(tracks) { track in
                    Text(track.name).tag(Optional(track.id))
                }
            }

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
    @State private var draft = AudioClipSettings.neutral
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
                Button("Apply") { commandContext.audioSettings = draft }
                    .disabled(draft == commandContext.audioSettings)
                Button("Reset Gain") { draft = .neutral }
            }
            .padding(.top, 4)
        } label: {
            Text("Audio").accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Audio")
        .accessibilityIdentifier("trimato.clip-editor.audio-filters")
        .onAppear { draft = commandContext.audioSettings ?? .neutral }
        .onChange(of: commandContext.audioSettings) { draft = commandContext.audioSettings ?? .neutral }
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
            get: { draft[keyPath: keyPath] },
            set: { value in
                var settings = draft
                settings[keyPath: keyPath] = value
                draft = settings
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
