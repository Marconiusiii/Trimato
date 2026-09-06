import SwiftUI
import AVFoundation

nonisolated enum AudioClipPreviewPlan {
    static func requiresRender(for settings: AudioClipSettings?) -> Bool {
        settings?.isNeutral == false
    }
}

struct SourceClipEditorView: View {
    @ObservedObject var controller: ProjectController
    let asset: MediaAssetRecord
    private var currentAsset: MediaAssetRecord { controller.asset(for: editSelection) ?? asset }
    let editSelection: EditorSelection
    let initialSegments: [SourceSegment]
    @ObservedObject var commandContext: ClipPlacementCommandContext

    @StateObject private var viewModel = VideoPlayerViewModel()
    @State private var loadedAssetID: UUID?
    @State private var preparingSource = false
    @State private var preparationID = UUID()
    @State private var preparationTask: Task<Void, Never>?
    @State private var sourcePreparationError: String?
    @State private var sourcePreparationProgress: Double?
    @State private var sourcePreparationDetail: String?
    @State private var sourcePreparationOutcome = OperationProgressOutcome.completed
    @State private var cacheOwnerID = UUID()
    @StateObject private var preview = ClipPreviewCoordinator()
    @State private var previewRequest: ClipPreviewCoordinator.Request?
    @State private var showsPreviewProgress = false
    @State private var showsPreviewError = false
    @State private var addingFilter = false
    @State private var pendingVoice: VoiceAdjustment?
    @FocusState private var addFilterKeyboardFocused: Bool
    @AccessibilityFocusState private var addFilterVoiceOverFocused: Bool
    @State private var pendingFilter: ClipFilter?
    @StateObject private var voiceWork = VoiceAdjustmentWork()
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
                    isPreparingSource: preparingSource,
                    isPreparingClipPreview: preview.state == .preparing
                )

                TabView(selection: $selectedTab) {
                    ClipMarkerControlsView(viewModel: viewModel)
                        .padding(8).tabItem { Text("Markers") }.tag("Markers")
                    if commandContext.audioSettings != nil {
                        AudioClipControlsView(commandContext: commandContext)
                            .padding(8).tabItem { Text("Audio") }.tag("Audio")
                    }
                    if commandContext.narrationTrack != nil {
                        VStack(alignment: .leading, spacing: 8) {
                            VoiceAdjustmentControls(settings: voiceBinding, controller: controller, work: voiceWork,
                                track: commandContext.narrationTrack, validateTake: commandContext.validateVoice,
                                applyTrack: commandContext.applyVoiceToTrack,
                                beforePlayback: { viewModel.player.pause() })
                            Button(voiceWork.playing ? "Stop playback" : "Play with show") {
                                if voiceWork.playing { voiceWork.cancel(); return }
                                viewModel.player.pause()
                                voiceWork.run {
                                    let url = try await commandContext.voiceMixedPreview()
                                    do { try voiceWork.play(url) }
                                    catch { try? FileManager.default.removeItem(at: url); throw error }
                                }
                            }.disabled(voiceWork.busy || !commandContext.effectsReady)
                        }
                        .padding(8).tabItem { Text("Voice") }.tag("Voice")
                    }
                    if commandContext.isTimelineEntry {
                        ClipFiltersView(context: commandContext, beforePlayback: { viewModel.player.pause(); voiceWork.cancel() })
                            .padding(8).tabItem { Text("Filters") }.tag("Filters")
                    }
                }
                .frame(height: selectedTab == "Voice" ? 335 : 170)
                .padding(.horizontal, 20)
                .disabled(viewModel.isExporting || viewModel.isPresentingExportPanel)

                if commandContext.isTimelineEntry {
                    HStack {
                        Button("Add Filter…") { addingFilter = true }
                            .focused($addFilterKeyboardFocused)
                            .accessibilityFocused($addFilterVoiceOverFocused)
                        if currentAsset.generator != nil {
                            Button("Edit Generator…") {
                                controller.requestGenerator(editing: editSelection)
                                if let id = controller.generatorRequestID {
                                    GeneratorWindowRegistry.shared.present(
                                        id: id,
                                        parentWindow: commandContext.hostWindow
                                    )
                                    controller.generatorRequestID = nil
                                }
                            }.disabled(commandContext.hasUncommittedChanges)
                        }
                    }.padding(.horizontal, 20)
                }
                if !preparingSource, loadedAssetID == nil {
                    if let sourcePreparationError {
                        Text(sourcePreparationError).padding(.horizontal, 20)
                    }
                    Button("Retry Clip Preparation", action: loadIfNeeded).padding(.horizontal, 20)
                }
                if voiceWork.busy {
                    HStack {
                        ProgressView("Preparing voice adjustments")
                        Button("Cancel preparation") { voiceWork.cancel() }
                    }.padding(.horizontal, 20)
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
        .operationProgress(
            clipPreparationOperation,
            outcome: clipPreparationOutcome,
            returnWindow: commandContext.hostWindow,
            waitsForReturnWindow: true
        )
        .operationProgress(showsPreviewProgress && preview.state == .preparing ? OperationProgress(
            title: "Applying Clip Effects", progress: preview.progress,
            cancel: preview.cancel
        ) : nil, outcome: previewOutcome)
        .sheet(isPresented: $addingFilter, onDismiss: finishAddingFilter) {
            AddClipFilterView(audio: commandContext.audioSettings != nil,
                              existing: commandContext.filters.map(\.kind),
                              voiceContext: commandContext,
                              addVoice: { voice in pendingVoice = voice; addingFilter = false },
                              beforePlayback: { viewModel.player.pause(); voiceWork.cancel() }) { filter in
                pendingFilter = filter
                addingFilter = false
            } cancel: { addingFilter = false }
        }
        .applicationMessage(voiceWork.message) { voiceWork.message = nil }
        .onChange(of: voiceWork.busy) { _, busy in commandContext.voiceWorkBusy = busy }
        .onChange(of: selectedTab) { voiceWork.cancel() }
        .onChange(of: commandContext.audioSettings) { voiceWork.player.pause() }
        .onDisappear { voiceWork.cancel(); commandContext.voiceWorkBusy = false }
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
            previewRequest = nil
            showsPreviewProgress = false
            preparationTask?.cancel()
            sourcePreparationProgress = nil
            sourcePreparationDetail = nil
            sourcePreparationOutcome = .completed
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
        .onChange(of: commandContext.filters) {
            scheduleAudioPreview(for: commandContext.audioSettings,
                                 userInitiated: commandContext.hasUncommittedChanges)
        }
        .onChange(of: viewModel.audioPreviewSegments) { scheduleAudioPreview(for: commandContext.audioSettings) }
        .onChange(of: commandContext.audioSettings) { _, settings in
            scheduleAudioPreview(for: settings,
                                 userInitiated: !commandContext.isTimelineEntry || commandContext.hasUncommittedChanges)
        }
        .sheet(isPresented: Binding(
            get: { commandContext.trackPlacementAction != nil },
            set: { if !$0 { commandContext.dismissTrackPlacement() } }
        )) {
            if let action = commandContext.trackPlacementAction {
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
    }

    private func finishAddingFilter() {
        if let pendingVoice {
            var audio = commandContext.audioSettings ?? .neutral
            audio.voice = pendingVoice
            commandContext.audioSettings = audio
            self.pendingVoice = nil
            selectedTab = "Filters"
        }
        if let pendingFilter {
            commandContext.filters.append(pendingFilter)
            self.pendingFilter = nil
            selectedTab = "Filters"
        }
        Task { @MainActor in
            await Task.yield()
            addFilterKeyboardFocused = true
            addFilterVoiceOverFocused = true
        }
    }

    private var trackPlacementPrimaryTitle: String {
        guard let action = commandContext.trackPlacementAction else { return "Add to Track" }
        return action.selectedTrackButtonTitle(audioOnly: commandContext.trackPlacementIsAudioOnly)
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
        sourcePreparationError = nil
        sourcePreparationProgress = nil
        sourcePreparationDetail = "\(currentAsset.name): Preparing media"
        sourcePreparationOutcome = .completed
        preparationTask = Task { @MainActor in
            defer {
                if preparationID == requestID {
                    preparingSource = false
                    preparationTask = nil
                }
            }
            do {
                let source = try await controller.preparedMediaSource(
                    for: currentAsset,
                    progress: { progress in
                        guard preparationID == requestID else { return }
                        sourcePreparationDetail = "\(currentAsset.name): Creating playback proxy"
                        sourcePreparationProgress = progress
                    }
                )
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
                guard preparationID == requestID else { return }
                loadedAssetID = nil
                sourcePreparationOutcome = .cancelled
                return
            } catch {
                guard preparationID == requestID else { return }
                loadedAssetID = nil
                sourcePreparationError = error.localizedDescription
                sourcePreparationOutcome = .failed
            }
        }
    }

    private var clipPreparationOperation: OperationProgress? {
        if preparingSource {
            return OperationProgress(
                title: "Preparing Clip",
                progress: sourcePreparationProgress,
                detail: sourcePreparationDetail,
                cancel: cancelClipPreparation
            )
        }
        guard viewModel.isPreparingMedia else { return nil }
        return OperationProgress(
            title: "Preparing Clip",
            progress: viewModel.mediaProgress,
            detail: clipPreparationDetail,
            cancel: cancelClipPreparation
        )
    }

    private var clipPreparationDetail: String? {
        guard let status = viewModel.mediaStatus else { return currentAsset.name }
        return "\(currentAsset.name): \(status)"
    }

    private var clipPreparationOutcome: OperationProgressOutcome {
        if sourcePreparationOutcome != .completed { return sourcePreparationOutcome }
        return viewModel.mediaPreparationOutcome
    }

    private func cancelClipPreparation() {
        preparationID = UUID()
        preparationTask?.cancel()
        preparationTask = nil
        preparingSource = false
        loadedAssetID = nil
        sourcePreparationProgress = nil
        sourcePreparationOutcome = .cancelled
        viewModel.cancelMediaLoad()
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

    private var voiceBinding: Binding<VoiceAdjustment> {
        Binding(get: {
            if let voice = commandContext.audioSettings?.voice { return voice }
            var voice = VoiceAdjustment()
            if let range = controller.captionDraftRange {
                voice.referenceStart = range.start.seconds
                voice.referenceEnd = range.end.seconds
            } else { voice.referenceEnd = min(5, controller.project.duration.seconds) }
            return voice
        }, set: { value in
            var audio = commandContext.audioSettings ?? .neutral
            audio.voice = value
            commandContext.audioSettings = audio
        })
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
                if showsPreviewError {
                    Text(preview.errorMessage ?? "The clip preview could not be updated.")
                        .textSelection(.enabled)
                }
                Menu("Preview Recovery") {
                    if preview.errorMessage != nil {
                        Button("Show Preview Error") { showsPreviewError = true }
                    }
                    Button("Retry Clip Preview") {
                        scheduleAudioPreview(for: commandContext.audioSettings, debounce: false, force: true,
                                             userInitiated: true)
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
        scheduleAudioPreview(for: commandContext.audioSettings, debounce: false, force: true, userInitiated: true)
    }

    private func scheduleAudioPreview(
        for settings: AudioClipSettings?,
        debounce: Bool = true,
        force: Bool = false,
        userInitiated: Bool = false
    ) {
        guard !viewModel.isLoadingMedia, !viewModel.isPreparingWaveform else { return }
        guard viewModel.hasMedia,
              let sourceURL = controller.resolveURL(for: currentAsset),
              !viewModel.audioPreviewSegments.isEmpty else {
            preview.reset()
            previewRequest = nil
            showsPreviewProgress = false
            commandContext.effectsReady = false
            viewModel.clipEffectsReady = false
            return
        }
        let request = ClipPreviewCoordinator.Request(
            source: sourceURL, filters: commandContext.filters,
            audio: commandContext.audioSettings != nil,
            segments: viewModel.audioPreviewSegments, audioSettings: settings
        )
        // Loading an existing clip and rebuilding after a source edit are
        // automatic. Only an explicit effects change or recovery opens progress.
        guard force || previewRequest != request else { return }
        previewRequest = request
        showsPreviewProgress = userInitiated
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

            if let error = commandContext.presentedError {
                Text(error.message)
                    .foregroundStyle(.red)
            }

            NativeModalActions(
                primaryTitle: action.selectedTrackButtonTitle(audioOnly: audioOnly),
                primaryEnabled: selectedTrackID != nil,
                cancel: cancel
            ) {
                guard let selectedTrackID else { return }
                addToTrack(selectedTrackID)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { selectedTrackID = tracks.first?.id }
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
                Button("Reset Gain") { draft.gainDecibels = 0 }
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
