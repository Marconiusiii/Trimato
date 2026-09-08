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
        editorContent
        .onChange(of: MediaFileReference(originalPath: currentAsset.originalPath, bookmarkData: currentAsset.bookmarkData,
                                         projectRelativePath: currentAsset.projectRelativePath ?? currentAsset.recordingRelativePath)) { _, _ in
            if asset.id == currentAsset.id { reloadLinkedSource() }
        }
        .onChange(of: controller.mediaFiles.missingIDs.contains(currentAsset.id)) { wasMissing, missing in
            if wasMissing && !missing { reloadLinkedSource() }
        }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.mediaFiles.missingIDs.contains(currentAsset.id) {
                Text("Source Missing. Relink this media from Project Source before editing.")
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
                            Button(voiceWork.playing ? "Stop playback" : "Play with Primary Audio") {
                                if voiceWork.playing { voiceWork.cancel(); return }
                                viewModel.player.pause()
                                voiceWork.run {
                                    let url = try await commandContext.voiceMixedPreview()
                                    do { try voiceWork.play(url) }
                                    catch { try? FileManager.default.removeItem(at: url); throw error }
                                }
                            }.disabled(voiceWork.busy)
                        }
                        .padding(8).tabItem { Text("Voice") }.tag("Voice")
                    }

                }
                .frame(height: selectedTab == "Voice" ? 335 : 170)
                .padding(.horizontal, 20)
                .disabled(viewModel.isExporting || viewModel.isPresentingExportPanel)

                if commandContext.audioSettings != nil {
                    MainEqualizerControls(context: commandContext)
                        .padding(.horizontal, 20)
                        .disabled(viewModel.isExporting || viewModel.isPresentingExportPanel)
                }
                if commandContext.isTimelineEntry {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Filters").font(.headline).accessibilityAddTraits(.isHeader)
                        Button("Add Filter…") { addingFilter = true }
                            .focused($addFilterKeyboardFocused)
                            .accessibilityFocused($addFilterVoiceOverFocused)
                        ClipFiltersView(context: commandContext, beforePlayback: { viewModel.player.pause(); voiceWork.cancel() })
                            .frame(height: 130)
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
                    Button("Retry Clip Preparation") { loadIfNeeded() }.padding(.horizontal, 20)
                }
                if voiceWork.busy {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Preparing voice adjustments…")
                        Button("Cancel preparation") { voiceWork.cancel() }
                    }.padding(.horizontal, 20)
                }
                previewStatus.padding(.horizontal, 20)

                Text("Export").font(.headline).accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                ClipExportControlsView(viewModel: viewModel)
                    .padding(.horizontal, 20)

                placementControls
                    .disabled(viewModel.isExporting || viewModel.isPresentingExportPanel)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
        }
        .blocksEditingDuringQuit()
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
            viewModel.preparePlayback = { ensureLatestPlayback() }
            loadIfNeeded()
        }
        .onChange(of: preview.state) { _, state in
            if state == .cancelled || preview.errorMessage != nil { viewModel.waitingForClipPreview = false }
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
            guard loadedAssetID == currentAsset.id, !preparingSource else { return }
            commandContext.setSegments(segments)
        }
        .onChange(of: viewModel.hasMedia) {
            guard viewModel.hasMedia else { return }
            viewModel.preparePlayback = { ensureLatestPlayback() }
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
            scheduleAudioPreview(for: settings, userInitiated: false)
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
        }
        if let pendingFilter {
            commandContext.filters.append(pendingFilter)
            self.pendingFilter = nil
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
        if commandContext.segments.isEmpty {
            Text("Choose a valid In and Out range to add or update this clip.")
        } else if commandContext.isTimelineEntry && !commandContext.hasUncommittedChanges {
            Text("No clip changes to update.")
        }
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
    private func reloadLinkedSource() {
        preparationTask?.cancel()
        loadedAssetID = nil
        preview.reset()
        previewRequest = nil
        viewModel.closeMedia()
        loadIfNeeded(preserveDraft: true)
    }

    private func loadIfNeeded(preserveDraft: Bool = false) {
        guard loadedAssetID != currentAsset.id else { return }
        loadedAssetID = currentAsset.id
        let segments = preserveDraft ? commandContext.segments : controller.segments(for: editSelection) ?? initialSegments
        if !preserveDraft { commandContext.setSegments(segments) }
        let opening = ClipEditorOpeningConfiguration.make(
            segments: segments,
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
                guard let source else {
                    controller.mediaFiles.refresh()
                    throw QuitDraftError(message: "Source Missing. Relink this media from Project Source.")
                }
                viewModel.load(
                    url: source.originalURL,
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
        VStack(alignment: .leading, spacing: 8) {
            if let previewStatusText { Text(previewStatusText) }
            if preview.state == .preparing {
                Button("Cancel preparation") { viewModel.waitingForClipPreview = false; preview.cancel() }
            }
            if previewNeedsRecovery {
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

    private var previewNeedsRecovery: Bool {
        switch preview.state {
        case .cancelled, .failed: true
        case .ready, .preparing: false
        }
    }

    private var previewStatusText: String? {
        switch preview.state {
        case .ready: nil
        case .preparing: "Preparing updated preview…"
        case .cancelled: "Clip preview preparation cancelled."
        case .failed: "Clip preview could not be updated."
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

    private func ensureLatestPlayback() -> Bool {
        guard let source = controller.resolveURL(for: currentAsset), !viewModel.audioPreviewSegments.isEmpty else { return false }
        let desired = ClipPreviewCoordinator.Request(source: source, filters: commandContext.filters,
            audio: commandContext.audioSettings != nil, segments: viewModel.audioPreviewSegments, audioSettings: commandContext.audioSettings)
        if preview.state == .ready && preview.lastSuccessfulRequest == desired { return true }
        if preview.state != .preparing || previewRequest != desired {
            scheduleAudioPreview(for: commandContext.audioSettings, debounce: false, force: true)
        }
        return preview.state == .ready && preview.lastSuccessfulRequest == desired
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
        let resume = viewModel.player.rate != 0 || viewModel.waitingForClipPreview
        viewModel.player.pause()
        viewModel.waitingForClipPreview = resume
        previewRequest = request
        showsPreviewProgress = userInitiated
        preview.update(request, debounce: debounce, force: force, soundFeedback: false, readiness: { ready in
            commandContext.effectsReady = ready
            viewModel.completePreviewPreparation(ready: ready)
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
    @ObservedObject var commandContext: ClipPlacementCommandContext
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AudioValueSlider(label: "Gain", value: Binding(
                get: { commandContext.audioSettings?.gainDecibels ?? 0 },
                set: { commandContext.audioSettings?.gainDecibels = $0 }),
                range: AudioClipControlSpecification.gainRange, step: AudioClipControlSpecification.decibelStep,
                unit: "dB", identifier: ClipEditorAccessibilityIdentifier.audioSlider("gain"))
            Button("Reset gain") { commandContext.audioSettings?.gainDecibels = 0 }
        }
    }
}

nonisolated enum EqualizerPreset: String, CaseIterable {
    case flat = "Flat", warmer = "Warmer voice", clearer = "Clearer speech", lessBass = "Less bass"
    func apply(to audio: inout AudioClipSettings) {
        let values: (Double, Double, Double)
        switch self {
        case .flat: values = (0, 0, 0)
        case .warmer: values = (3, 0, -2)
        case .clearer: values = (-2, 3, 2)
        case .lessBass: values = (-6, 0, 0)
        }
        audio.lowGainDecibels = values.0
        audio.midGainDecibels = values.1
        audio.highGainDecibels = values.2
    }
}

struct MainEqualizerControls: View {
    @ObservedObject var context: ClipPlacementCommandContext
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Equalizer").font(.headline).accessibilityAddTraits(.isHeader)
                Menu("EQ presets") {
                    ForEach(EqualizerPreset.allCases, id: \.self) { preset in
                        Button(preset.rawValue) {
                            guard var audio = context.audioSettings else { return }
                            preset.apply(to: &audio)
                            context.audioSettings = audio
                        }
                    }
                }
            }
            HStack {
            AudioValueSlider(label: "Bass", value: binding(\.lowGainDecibels), range: -12...12, step: 0.5, unit: "dB", identifier: "trimato.eq.bass")
            AudioValueSlider(label: "Midrange", value: binding(\.midGainDecibels), range: -12...12, step: 0.5, unit: "dB", identifier: "trimato.eq.mid")
            AudioValueSlider(label: "Treble", value: binding(\.highGainDecibels), range: -12...12, step: 0.5, unit: "dB", identifier: "trimato.eq.treble")
            }
            Toggle("Reduce low rumble", isOn: binding(\.highPassEnabled)).toggleStyle(.switch)
            if context.audioSettings?.highPassEnabled == true {
                AudioValueSlider(label: "Rumble cutoff", value: binding(\.highPassFrequency), range: 20...2000, step: 10, unit: "Hz", identifier: "trimato.eq.rumble")
            }
            Toggle("Reduce high-frequency hiss", isOn: binding(\.lowPassEnabled)).toggleStyle(.switch)
            if context.audioSettings?.lowPassEnabled == true {
                AudioValueSlider(label: "Hiss cutoff", value: binding(\.lowPassFrequency), range: 1000...20000, step: 100, unit: "Hz", identifier: "trimato.eq.hiss")
            }
        }
    }
    private func binding<T>(_ key: WritableKeyPath<AudioClipSettings, T>) -> Binding<T> {
        Binding(get: { (context.audioSettings ?? .neutral)[keyPath: key] }, set: { context.audioSettings?[keyPath: key] = $0 })
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
