import AppKit
import AVFoundation
import Combine
import SwiftUI

@MainActor
final class ProjectRecordingSession: ObservableObject, Identifiable {
    let id = UUID()
    let purpose: RecordingPurpose
    weak var controller: ProjectController?
    let capture = AudioCaptureSession()
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
    private let processingSound = ProcessingSound()
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

    init(controller: ProjectController, purpose: RecordingPurpose, cue: CaptionCue? = nil) {
        self.controller = controller
        self.purpose = purpose
        editingCueID = cue?.id
        let insertion = cue?.start.seconds ?? (purpose == .audioDescription ? controller.captionDraftRange?.start.seconds : nil) ?? controller.timelinePlayhead.seconds
        start = insertion
        end = cue?.end.seconds ?? controller.captionDraftRange?.end.seconds ?? min(controller.project.duration.seconds, insertion + 5)
        text = cue?.text ?? ""
        name = purpose.title
        ducking = controller.project.descriptionDucking
        if let reference = controller.captionDraftRange {
            voice.referenceStart = reference.start.seconds
            voice.referenceEnd = reference.end.seconds
        } else { voice.referenceEnd = min(5, controller.project.duration.seconds) }
        capture.maximumDuration = nil
        AudioOutputManager.shared.register(player)
        AudioOutputManager.shared.register(takePlayer)
        takeRateObserver = takePlayer.publisher(for: \.rate).receive(on: RunLoop.main).sink { [weak self] in self?.takePlaying = $0 != 0 }
        rateObserver = player.publisher(for: \.rate).receive(on: RunLoop.main).sink { [weak self] in self?.playing = $0 != 0 }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in self?.position = max(0, time.seconds) }
        }
        originalQuitDraft = quitDraft
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
            takePlayer.replaceCurrentItem(with: nil)
            guard validRange else { fail("Set a valid insertion time and, for Describer, an Out point after the In point."); return }
            if controller?.project.tracks.contains(where: { !$0.clips.isEmpty }) == true {
                preparingRecording = true
                preview(mixed: false, autoplay: false, recording: true, soundFeedback: true)
            } else { capture.setRecording(true, input: input) }
        } else { capture.setRecording(false, input: input) }
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
            defer { busy = false; preparingRecording = false }
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
                try Task.checkCancellation()
                processingSound.stopBeforePlayback()
                if autoplay { player.play() }
                if recording { capture.setRecording(true, input: input) }
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
    var hasPendingQuitEdits: Bool { capture.isBusy || capture.testURL != nil || quitDraft != originalQuitDraft }
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
        processingSound.start()
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
                let (source, duration) = try await preparedTake()
                let folder = try await controller.recordingsDirectory()
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
        operation?.cancel()
        player.pause()
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
    @ObservedObject var session: ProjectRecordingSession
    @ObservedObject private var capture: AudioCaptureSession
    @Environment(\.controlActiveState) private var windowActivity
    @State private var didSetInitialFocus = false
    private enum Field: Hashable { case name, transcript }
    @FocusState private var keyboardFocus: Field?
    @AccessibilityFocusState private var textFocus: Field?
    @StateObject private var voiceWork = VoiceAdjustmentWork()
    @State private var selectedTab = "Recording"

    init(session: ProjectRecordingSession) {
        self.session = session
        _capture = ObservedObject(wrappedValue: session.capture)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.purpose.toolTitle).font(.title2).accessibilityAddTraits(.isHeader)
            VideoPlayerView(player: session.player).frame(height: 140)
            LabeledContent("Clip name") {
                TextField("", text: $session.name)
                    .focused($keyboardFocus, equals: .name)
                    .accessibilityFocused($textFocus, equals: .name)
                    .disabled(session.saving)
                    .labelsHidden()
            }
            TabView(selection: $selectedTab) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
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
                        LabeledContent("Description text") {
                            TextEditor(text: $session.text)
                            .labelsHidden()
                            .focused($keyboardFocus, equals: .transcript)
                            .accessibilityFocused($textFocus, equals: .transcript)
                            .frame(height: 80)
                            .disabled(session.saving)
                        }
                        HStack {
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
                    HStack {
                        Toggle("Record", isOn: Binding(get: { capture.isRecordingRequested || session.preparingRecording }, set: { session.toggleRecording($0) }))
                            .toggleStyle(.button)
                            .disabled(session.busy && !session.preparingRecording)
                        Button(session.takePlaying ? "Stop take" : "Play take") { session.playTake() }
                            .disabled(capture.testURL == nil || capture.isBusy || session.busy)
                        Button("Play with Primary Audio") { session.preview(mixed: true, soundFeedback: true) }
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
                .padding(8).tabItem { Text("Recording") }.tag("Recording")
                if let controller = session.controller {
                    VStack(alignment: .leading, spacing: 10) {
                        VoiceAdjustmentControls(settings: $session.voice, controller: controller, work: voiceWork,
                            track: session.voiceTrack, validateTake: session.validateVoice,
                            applyTrack: { settings in
                                if let track = session.voiceTrack { try await controller.applyVoiceToTrack(track.id, settings: settings) }
                            }, beforePlayback: session.stopPlayback)
                        HStack {
                            Button(session.takePlaying ? "Stop take" : "Play take") { voiceWork.cancel(); session.playTake() }
                            Button("Play with Primary Audio") { voiceWork.cancel(); session.preview(mixed: true, soundFeedback: true) }
                        }.disabled(capture.testURL == nil || session.busy || voiceWork.busy)
                        Spacer(minLength: 0)
                    }
                    .disabled(capture.isBusy || session.busy)
                    .padding(8).tabItem { Text("Voice") }.tag("Voice")
                }
            }
            .frame(height: session.isDescriber ? 385 : 330)
            .disabled(voiceWork.busy)
            if voiceWork.busy {
                HStack { ProgressView("Preparing voice adjustments"); Button("Cancel preparation") { voiceWork.cancel() } }
            }
            if session.busy { ProgressView("Preparing…").controlSize(.small) }
            HStack {
                Button("Cancel") { session.controller?.dismissRecording() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(session.saveTitle) { session.save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.busy || voiceWork.busy || capture.isBusy || !session.validRange)
            }
        }
        .padding(20)
        .frame(width: 620)
        .interactiveDismissDisabled()
        .onChange(of: capture.state) { _, state in
            if state == .recording { session.player.play() }
            else if state == .idle || state == .finishing {
                session.player.pause()
                if state == .finishing { session.player.replaceCurrentItem(with: nil) }
            }
        }
        .defaultFocus($keyboardFocus, .name)
        .onChange(of: windowActivity, initial: true) { _, activity in
            guard activity == .key, !didSetInitialFocus else { return }
            didSetInitialFocus = true
            Task { @MainActor in
                await Task.yield()
                keyboardFocus = .name
                textFocus = .name
            }
        }
        .task {
            if session.validRange, session.controller?.project.tracks.contains(where: { !$0.clips.isEmpty }) == true {
                session.preview(mixed: false, autoplay: false, soundFeedback: false)
            }
        }
        .task(id: session.ducking) { await session.applyDucking() }
        .onChange(of: selectedTab) { voiceWork.cancel(); if !capture.isBusy { session.stopPlayback() } }
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
