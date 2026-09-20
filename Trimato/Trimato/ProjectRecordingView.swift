import AppKit
import AVFoundation
import Combine
import SwiftUI

@MainActor
final class ProjectRecordingSession: ObservableObject, Identifiable {
    let id = UUID()
    let purpose: RecordingPurpose
    weak var controller: ProjectController?
    let capture: AudioCaptureSession
    let input = AudioInputManager.shared
    let player = AVPlayer()
    private let takePlayer = AVPlayer()
    @Published var start: Double
    @Published var end: Double
    @Published var text: String
    @Published var name: String
    @Published var voice = VoiceAdjustment()
    @Published var fitLongTake = false
    @Published var trimLongTake = false
    @Published var ducking: DescriptionDucking
    private let processingSound: ProcessingSound
    private let recordingDirectory: () async throws -> URL
    private let startCapture: () -> Void
    private let prepareCapture: () -> Void
    @Published private(set) var inputPreparationStarted = false
    var canStartRecording: Bool { inputPreparationStarted && capture.canStartRecording }
    @Published var busy = false {
        didSet { if !busy { processingSound.stop() } }
    }
    @Published var saving = false
    @Published var preparingRecording = false
    @Published var message: ApplicationMessageDescriptor?
    @Published var position = 0.0
    @Published var playing = false
    @Published var takePlaying = false
    private let editingCueID: UUID?
    private var operation: Task<Void, Never>?
    private var timeObserver: Any?
    private var rateObserver: AnyCancellable?
    private var takeRateObserver: AnyCancellable?
    private var temporaryURLs: [URL] = []
    private var showPreview: (project: TrimatoProject, result: ProjectCompositionResult)?
    private var closed = false
    private var originalQuitDraft: QuitDraft?
    private var previewIncludesTake = false

    var saveTitle: String { editingCueID == nil ? "Add to Project" : "Save Description" }
    var isDescriber: Bool { purpose == .audioDescription }
    var range: ProjectTimeRange { ProjectTimeRange(start: ProjectTime(seconds: start), duration: ProjectTime(seconds: end - start)) }
    var validRange: Bool { start.isFinite && start >= 0 && (!isDescriber || (end.isFinite && end > start)) }

    init(controller: ProjectController, purpose: RecordingPurpose, cue: CaptionCue? = nil,
         capture: AudioCaptureSession? = nil, processingSound: ProcessingSound? = nil,
         recordingDirectory: (() async throws -> URL)? = nil,
         startCapture: (() -> Void)? = nil, prepareCapture: (() -> Void)? = nil) {
        let recordingCapture = capture ?? AudioCaptureSession()
        self.capture = recordingCapture
        self.startCapture = startCapture ?? { recordingCapture.setRecording(true, input: AudioInputManager.shared) }
        self.prepareCapture = prepareCapture ?? { recordingCapture.prepareInput(input: AudioInputManager.shared) }
        self.processingSound = processingSound ?? ProcessingSound()
        self.recordingDirectory = recordingDirectory ?? { [weak controller] in
            guard let controller else { throw CancellationError() }
            return try await controller.recordingsDirectory()
        }
        self.controller = controller
        self.purpose = purpose
        editingCueID = cue?.id
        let insertion = cue?.start.seconds ?? (purpose == .audioDescription ? controller.captionDraftRange?.start.seconds : nil) ?? controller.timelinePlayhead.seconds
        start = insertion
        position = insertion
        end = cue?.end.seconds ?? controller.captionDraftRange?.end.seconds ?? min(controller.project.duration.seconds, insertion + 5)
        text = cue?.text ?? ""
        name = ""
        ducking = controller.project.descriptionDucking
        if let reference = controller.captionDraftRange {
            voice.referenceStart = reference.start.seconds
            voice.referenceEnd = reference.end.seconds
        } else { voice.referenceEnd = min(5, controller.project.duration.seconds) }
        self.capture.maximumDuration = nil
        AudioOutputManager.shared.register(player)
        AudioOutputManager.shared.register(takePlayer)
        takeRateObserver = takePlayer.publisher(for: \.rate).receive(on: RunLoop.main).sink { [weak self] in self?.takePlaying = $0 != 0 }
        rateObserver = player.publisher(for: \.rate).receive(on: RunLoop.main).sink { [weak self] in self?.playing = $0 != 0 }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, !self.closed, time.seconds.isFinite else { return }
                self.position = max(0, time.seconds)
            }
        }
        controller.projectPlayer?.beginAuthoringPlayback(id: id)
        originalQuitDraft = quitDraft
    }

    func prepareRecordingInput() {
        guard !closed, !inputPreparationStarted else { return }
        inputPreparationStarted = true
        prepareCapture()
    }

    func toggleRecording(_ enabled: Bool) {
        if !enabled, preparingRecording {
            processingSound.stop()
            operation?.cancel()
            preparingRecording = false
            return
        }
        guard !busy else { return }
        player.pause()
        if enabled {
            guard canStartRecording else { return }
            takePlayer.replaceCurrentItem(with: nil)
            guard validRange else { fail("Set a valid insertion time and, for Describer, an Out point after the In point."); return }
            AudioCaptureSession.beginQuietPreparation(id)
            if controller?.project.tracks.contains(where: { !$0.clips.isEmpty }) == true {
                preparingRecording = true
                preview(mixed: false, autoplay: false, recording: true, soundFeedback: false)
            } else {
                startCapture()
                AudioCaptureSession.endQuietPreparation(id)
            }
        } else { capture.setRecording(false, input: input) }
    }

    func playProjectRange() {
        preview(mixed: false, soundFeedback: true)
    }

    func stopPlayback() {
        takePlayer.pause()
        player.pause()
        capture.setTestPlayback(false)
    }

    func preview(mixed: Bool, autoplay: Bool = true, recording: Bool = false, seekTime: Double? = nil, soundFeedback: Bool = false) {
        if player.rate != 0 && autoplay && seekTime == nil { stopPlayback(); return }
        guard !busy, !capture.isBusy, let controller else { return }
        stopPlayback()
        guard validRange else { fail("Set a valid In and Out point before playback."); return }
        let playbackRange = RecordingPreviewRange(start: start, end: end, bounded: isDescriber)
        let requestedStart = playbackRange.start
        let requestedPosition = playbackRange.position(resuming: seekTime)
        let requestedDucking = ducking
        let requestedVoice = voice
        previewIncludesTake = mixed
        player.replaceCurrentItem(with: nil)
        clearPreviewFiles()
        busy = true
        if soundFeedback { processingSound.start() }
        operation = Task { [weak self] in
            guard let self else { return }
            defer {
                busy = false
                preparingRecording = false
                if recording { AudioCaptureSession.endQuietPreparation(id) }
            }
            var pendingMedia: [URL] = []
            defer { for url in pendingMedia { try? FileManager.default.removeItem(at: url) } }
            do {
                var project = controller.project
                if isDescriber { project.descriptionDucking = requestedDucking }
                var urls = controller.resolvedMediaURLs()
                if mixed, capture.testURL != nil {
                    let (url, duration) = try await preparedTake()
                    let asset = recordingAsset(url: url, duration: duration)
                    let clipID = project.putRecording(asset, at: ProjectTime(seconds: requestedStart))
                    var audio = AudioClipSettings.neutral
                    audio.voice = requestedVoice
                    try project.setClipEffects(id: clipID, audio: audio, filters: nil)
                    project.descriptionDucking = requestedDucking
                    urls[asset.id] = url
                }
                let result: ProjectCompositionResult
                let reused = !mixed && showPreview?.project == project
                if reused, let saved = showPreview {
                    result = saved.result
                } else {
                    result = try await ProjectCompositionBuilder.build(project: project, mediaURLs: urls)
                    pendingMedia = result.temporaryMediaURLs
                }
                try Task.checkCancellation()
                guard !closed else { return }
                if mixed { temporaryURLs.append(contentsOf: result.temporaryMediaURLs) }
                else if !reused {
                    clearShowPreview()
                    showPreview = (project, result)
                }
                pendingMedia = []
                let item = AVPlayerItem(asset: result.composition)
                item.videoComposition = result.videoComposition
                item.audioMix = result.audioMix
                item.audioTimePitchAlgorithm = .spectral
                if let end = playbackRange.end { item.forwardPlaybackEndTime = ProjectTime(seconds: end).cmTime }
                player.replaceCurrentItem(with: item)
                let sought = await player.seek(to: ProjectTime(seconds: requestedPosition).cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
                guard sought, player.currentItem === item else { throw CancellationError() }
                position = requestedPosition
                try Task.checkCancellation()
                processingSound.stopBeforePlayback()
                if autoplay { player.play() }
                if recording { startCapture() }
            } catch is CancellationError { }
            catch { fail(error.localizedDescription) }
        }
    }

    func applyDucking() async {
        guard isDescriber else { return }
        do {
            // Commit complete edits, outside presentation/layout and capture preparation.
            try await Task.sleep(for: .milliseconds(200))
            while busy || capture.isBusy {
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
            guard !closed, let controller, controller.project.descriptionDucking != ducking else { return }
            controller.updateDescriptionDucking(ducking)
            guard player.currentItem != nil else { return }
            let resume = playing
            let time = position
            stopPlayback()
            preview(mixed: previewIncludesTake, autoplay: resume, seekTime: time)
        } catch is CancellationError { }
        catch { fail(error.localizedDescription) }
    }

    func playTake() {
        guard !busy, !capture.isBusy else { return }
        if takePlaying { stopPlayback(); return }
        stopPlayback()
        busy = true
        processingSound.start()
        operation = Task { [weak self] in
            guard let self else { return }
            defer { busy = false }
            do {
                let url = try await processedTake(voice)
                try Task.checkCancellation()
                takePlayer.replaceCurrentItem(with: AVPlayerItem(url: url))
                processingSound.stopBeforePlayback()
                takePlayer.play()
            } catch is CancellationError { }
            catch { fail(error.localizedDescription) }
        }
    }

    var voiceTrack: TimelineTrack? {
        let length = capture.summary?.duration ?? 0
        let fitted = (fitLongTake || trimLongTake) && isDescriber ? min(length, max(0, end - start)) : length
        return controller?.project.recordingDestination(purpose: purpose, start: ProjectTime(seconds: start), duration: ProjectTime(seconds: fitted))
    }

    func validateVoice(_ settings: VoiceAdjustment) async throws {
        guard capture.testURL != nil else { return }
        _ = try await processedTake(settings)
    }

    private func processedTake(_ settings: VoiceAdjustment) async throws -> URL {
        let (url, duration) = try await preparedTake()
        guard settings.isActive else { return url }
        var audio = AudioClipSettings.neutral
        audio.voice = settings
        let output = try await ClipFilterRenderer.render(source: url, filters: [], audio: true,
            duration: duration, audioSettings: audio)
        temporaryURLs.append(output)
        return output
    }

    private func preparedTake() async throws -> (URL, Double) {
        guard let url = capture.testURL, let duration = capture.summary?.duration, duration > 0 else {
            throw AudioCaptureError.message("Record a take first.")
        }
        let result = try await RecordingTakeProcessor.prepare(
            url: url, duration: duration, available: isDescriber ? end - start : nil,
            speedUp: fitLongTake, trim: trimLongTake)
        if result.url != url { temporaryURLs.append(result.url) }
        return result
    }

    private func recordingAsset(url: URL, duration: Double) -> MediaAssetRecord {
        let length = ProjectTime(seconds: duration)
        var asset = MediaAssetRecord(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? purpose.title : name,
                                     originalPath: url.path, duration: length, hasAudio: true,
                                     sourceEdit: [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: length))])
        asset.playbackMode = .nativePassthrough
        asset.recordingPurpose = purpose
        return asset
    }

    struct QuitDraft: Equatable {
        let name: String
        let text: String
        let start: Double
        let end: Double
        let voice: VoiceAdjustment
        let ducking: DescriptionDucking
        let take: URL?
        let speed: Bool
        let trim: Bool
    }
    var quitDraft: QuitDraft {
        QuitDraft(name: name, text: text, start: start, end: end, voice: voice, ducking: ducking,
                  take: capture.testURL, speed: fitLongTake, trim: trimLongTake)
    }
    var hasPendingQuitEdits: Bool { capture.hasPendingTake || quitDraft != originalQuitDraft }
    func validateForQuit() throws {
        guard validRange else { throw QuitDraftError(message: "Set a valid recording In and Out range before saving.") }
        guard !capture.isBusy, !busy else { throw QuitDraftError(message: "Stop recording and wait for the take to finish before saving.") }
        guard ducking.decibels.isFinite, (-60...0).contains(ducking.decibels),
              ducking.fadeSeconds.isFinite, (0.01...5).contains(ducking.fadeSeconds) else {
            throw QuitDraftError(message: "Use an Audio Ducking Amount from −60 to 0 dB and a fade time from 0.01 to 5 seconds.")
        }
        try voice.validate()
    }

    func save() {
        do { try validateForQuit() } catch { fail(error.localizedDescription); return }
        busy = true
        saving = true
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try await persistRecording()
                controller?.dismissRecording()
            } catch is CancellationError { }
            catch { fail(error.localizedDescription) }
        }
    }

    func saveForQuit() async throws {
        try validateForQuit()
        try await persistRecording()
    }

    private func persistRecording() async throws {
        guard let controller else { throw QuitDraftError(message: "The recording project is no longer open.") }
        stopPlayback()
        busy = true
        saving = true
        defer { busy = false; saving = false }
        var savedURL: URL?
        do {
            var cue: CaptionCue?
            if isDescriber, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cue = try CaptionCue(id: editingCueID ?? UUID(), start: range.start, end: range.end, text: text).validated()
            }
            var asset: MediaAssetRecord?
            if capture.testURL != nil {
                // Resolve user interaction before starting processing feedback or file work.
                processingSound.stop()
                let folder = try await recordingDirectory()
                try Task.checkCancellation()
                processingSound.start()
                let (source, duration) = try await preparedTake()
                try Task.checkCancellation()
                let cleanName = name.components(separatedBy: CharacterSet(charactersIn: "/:\n\r")).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let filename = String((cleanName.isEmpty ? purpose.title : cleanName).prefix(80))
                let url = folder.appendingPathComponent("\(filename) \(UUID().uuidString).wav")
                try await RecordingFileStorage.copy(from: source, to: url)
                savedURL = url
                var record = recordingAsset(url: url, duration: duration)
                record.bookmarkData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                record.recordingRelativePath = "Recordings/\(url.lastPathComponent)"
                asset = record
            }
            guard asset != nil || cue != nil else { throw AudioCaptureError.message(isDescriber ? "Enter description text or record a take." : "Record a take first.") }
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            try voice.validate()
            if asset != nil { try await validateVoice(voice) }
            try Task.checkCancellation()
            try controller.addProjectRecording(asset: asset, at: ProjectTime(seconds: start), cue: cue, ducking: ducking, voice: voice)
        } catch {
            if let savedURL { await RecordingFileStorage.remove(savedURL) }
            throw error
        }
    }

    func close() {
        guard !closed else { return }
        processingSound.stop()
        closed = true
        AudioCaptureSession.endQuietPreparation(id)
        operation?.cancel()
        player.pause()
        controller?.projectPlayer?.endAuthoringPlayback(id: id, at: ProjectTime(seconds: position))
        player.replaceCurrentItem(with: nil)
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        rateObserver = nil
        takeRateObserver = nil
        takePlayer.pause()
        takePlayer.replaceCurrentItem(with: nil)
        capture.close()
        clearPreviewFiles()
        clearShowPreview()
    }
    private func clearShowPreview() {
        for url in showPreview?.result.temporaryMediaURLs ?? [] { try? FileManager.default.removeItem(at: url) }
        showPreview = nil
    }
    private func clearPreviewFiles() {
        for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
        temporaryURLs.removeAll()
    }
    private func fail(_ text: String) { message = ApplicationMessageDescriptor(title: purpose.toolTitle, message: text) }
}

struct ProjectRecordingView: View {
    @AppStorage(AppPreferenceKey.precisionTimecode) private var precisionTimecode = true
    @ObservedObject var session: ProjectRecordingSession
    @ObservedObject private var capture: AudioCaptureSession
    let focusRevision: Int
    @Environment(\.controlActiveState) private var windowActivity
    @State private var appliedFocusRevision: Int?
    private enum Field: Hashable { case name, transcript }
    @FocusState private var keyboardFocus: Field?
    @AccessibilityFocusState private var textFocus: Field?
    @StateObject private var voiceWork = VoiceAdjustmentWork()

    init(session: ProjectRecordingSession, focusRevision: Int = 0) {
        self.session = session
        self.focusRevision = focusRevision
        _capture = ObservedObject(wrappedValue: session.capture)
    }
    var body: some View {
        VStack(spacing: 0) {
            form
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            actions.padding(EditorTheme.dialogPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var actions: some View {
        HStack {
            Spacer()
            Button("Cancel") { session.controller?.requestCloseToolPane() }.keyboardShortcut(.cancelAction)
            Button(session.saveTitle) { session.save() }
                .buttonStyle(.borderedProminent)
                .editorPrimaryAction()
                .keyboardShortcut(.defaultAction)
                .disabled(session.busy || voiceWork.busy || capture.isBusy || !session.validRange)
            ContextualHelpButton(topic: session.isDescriber ? .describer : .voicer)
        }
    }

    private var recordingFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent(session.isDescriber ? "In" : "Insert at") {
                    TextField("", value: $session.start, format: RecordingTimeFormat()).labelsHidden()
                }
                if session.isDescriber {
                    LabeledContent("Out") { TextField("", value: $session.end, format: RecordingTimeFormat()).labelsHidden() }
                }
            }
            .disabled(capture.isBusy || session.busy)
            if session.isDescriber {
                Text("Description transcript").font(.headline).accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $session.text)
                    .accessibilityLabel("Description text")
                    .focused($keyboardFocus, equals: .transcript)
                    .accessibilityFocused($textFocus, equals: .transcript)
                    .frame(minHeight: 100, idealHeight: 220, maxHeight: .infinity)
                    .disabled(session.saving)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Speed up to fit", isOn: $session.fitLongTake)
                        .onChange(of: session.fitLongTake) { _, value in if value { session.trimLongTake = false } }
                    Toggle("Trim at Out", isOn: $session.trimLongTake)
                        .onChange(of: session.trimLongTake) { _, value in if value { session.fitLongTake = false } }
                }
                .disabled(session.busy || capture.isBusy)
                Toggle("Audio Ducking", isOn: $session.ducking.enabled)
                    .toggleStyle(.switch)
                    .disabled(session.busy || capture.isBusy)
                if session.ducking.enabled {
                    LabeledContent("Audio Ducking Amount") {
                        TextField("", value: $session.ducking.decibels, format: .number.precision(.fractionLength(0...1))).labelsHidden()
                        Text("dB").accessibilityHidden(true)
                    }
                    .disabled(session.busy || capture.isBusy)
                    LabeledContent("Fade time, seconds") {
                        TextField("", value: $session.ducking.fadeSeconds, format: .number.precision(.fractionLength(0...2))).labelsHidden()
                    }
                    .disabled(session.busy || capture.isBusy)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var takeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Record", isOn: Binding(get: { capture.isRecordingRequested || session.preparingRecording }, set: { voiceWork.cancel(); session.toggleRecording($0) }))
                    .toggleStyle(.button)
                    .disabled((session.busy && !session.preparingRecording)
                        || (!capture.isRecordingRequested && !session.preparingRecording && !session.canStartRecording))
                Button(session.takePlaying ? "Stop take" : "Play take") { voiceWork.cancel(); session.playTake() }
                    .disabled(capture.testURL == nil || capture.isBusy || session.busy)
            }
            HStack {
                Button(session.playing ? "Stop playback" : "Play with Primary Audio") { voiceWork.cancel(); session.preview(mixed: true, soundFeedback: true) }
                    .disabled(capture.testURL == nil || capture.isBusy || session.busy)
                Button("Delete take") { session.stopPlayback(); capture.deleteTest() }
                    .disabled(capture.testURL == nil || capture.isBusy || session.busy)
            }
            if let summary = capture.summary {
                Text("Take length: \(summary.duration, specifier: "%.2f") seconds")
                if session.isDescriber && summary.duration > session.end - session.start {
                    Text("Beyond Out: \(summary.duration - (session.end - session.start), specifier: "%.2f") seconds")
                }
            }
        }
    }

    @ViewBuilder private var recordingTabs: some View {
        if #available(macOS 15, *) {
            tabContent.tabViewStyle(.grouped)
        } else {
            tabContent
        }
    }

    private var tabContent: some View {
        TabView {
            recordingFields
                .tabItem { Text("Recording") }
            if let controller = session.controller {
                VoiceAdjustmentControls(settings: $session.voice, controller: controller, work: voiceWork,
                    track: session.voiceTrack, compact: true, validateTake: session.validateVoice,
                    applyTrack: { settings in
                        if let track = session.voiceTrack { try await controller.applyVoiceToTrack(track.id, settings: settings) }
                    }, beforePlayback: session.stopPlayback)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .disabled(capture.isBusy || session.busy)
                    .tabItem { Text("Voice Adjustments") }
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.purpose.toolTitle).font(EditorTheme.dialogTitle).accessibilityAddTraits(.isHeader)
            if session.isDescriber {
                LabeledContent("Timecode") {
                    Text(AppPreferences.passiveTimecode(seconds: session.position, precision: precisionTimecode))
                        .monospacedDigit()
                }
            } else {
                Text("Project time: \(AppPreferences.passiveTimecode(seconds: session.position, precision: precisionTimecode))")
                    .monospacedDigit()
            }
            HStack {
                Button(session.isDescriber
                    ? (session.playing ? "Stop playback" : "Play project range")
                    : (session.playing ? "Stop Playback" : "Play Project from Insertion Point")) {
                    voiceWork.cancel(); session.playProjectRange()
                }
                .disabled(session.busy || capture.isBusy || !session.validRange)
            }
            LabeledContent("\(session.purpose.toolTitle) Clip Name") {
                TextField("", text: $session.name)
                    .focused($keyboardFocus, equals: .name)
                    .accessibilityFocused($textFocus, equals: .name)
                    .disabled(session.saving)
                    .labelsHidden()
            }
            recordingTabs
            .frame(minHeight: 0, maxHeight: .infinity)
            .disabled(voiceWork.busy)
            takeControls
                .disabled(voiceWork.busy)
            if voiceWork.busy {
                HStack { ProgressView("Preparing voice adjustments"); Button("Cancel preparation") { voiceWork.cancel() } }
            }
            ProgressView(capture.isPreparingInput ? "Preparing microphone…" : "Preparing…")
                .controlSize(.small)
                .opacity(capture.isPreparingInput || (session.busy && !session.preparingRecording) ? 1 : 0)
                .accessibilityHidden(!capture.isPreparingInput && (!session.busy || session.preparingRecording))

        }
        .padding(EditorTheme.dialogPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .interactiveDismissDisabled()
        .onChange(of: capture.state) { _, state in
            if state == .recording { session.player.play() }
            else if state == .idle || state == .finishing {
                session.player.pause()
            }
        }
        .defaultFocus($keyboardFocus, .name)
        .task(id: windowActivity == .key ? focusRevision : nil) {
            guard windowActivity == .key, appliedFocusRevision != focusRevision else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            appliedFocusRevision = focusRevision
            keyboardFocus = .name
            textFocus = .name
        }
        .task {
            if session.validRange, session.controller?.project.tracks.contains(where: { !$0.clips.isEmpty }) == true {
                session.preview(mixed: false, autoplay: false, soundFeedback: false)
            }
            session.prepareRecordingInput()
        }
        .task(id: session.ducking) { await session.applyDucking() }
        .onChange(of: session.voice) { session.stopPlayback() }
        .pendingQuitDraft(session.quitDraft, pending: session.hasPendingQuitEdits,
            validate: { try session.validateForQuit() }, apply: { try await session.saveForQuit(); session.controller?.dismissRecording() })
        .onDisappear { voiceWork.cancel(); session.close() }
        .applicationMessage(voiceWork.message ?? session.message ?? capture.message) { voiceWork.message = nil; session.message = nil; capture.message = nil }
    }
}

/// Disk operations must not block keyboard, playback, or quit cancellation handling.
nonisolated enum RecordingFileStorage {
    static func copy(from source: URL, to destination: URL) async throws {
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let staging = destination.deletingLastPathComponent()
                .appendingPathComponent(".trimato-recording-\(UUID()).tmp")
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.copyItem(at: source, to: staging)
            try Task.checkCancellation()
            // Move only a complete recording into place; never overwrite an existing file.
            try FileManager.default.moveItem(at: staging, to: destination)
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: destination)
                throw CancellationError()
            }
        }
        try await withTaskCancellationHandler {
            try await work.value
        } onCancel: { work.cancel() }
    }

    static func prepareDirectory(_ folder: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let probe = folder.appendingPathComponent(".trimato-write-\(UUID())")
            defer { try? FileManager.default.removeItem(at: probe) }
            try Data().write(to: probe, options: .atomic)
        }.value
        try Task.checkCancellation()
    }

    static func remove(_ url: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }.value
    }
}
