import AVFoundation
import Combine
import SwiftUI

@MainActor
final class VoiceAdjustmentWork: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var playing = false
    @Published var message: ApplicationMessageDescriptor?
    let player = AVPlayer()
    private let sliderKeyboard = SettingsSliderKeyboard(identifier: "trimato.voice.level")
    func startKeyboard() { sliderKeyboard.start() }
    func stopKeyboard() { sliderKeyboard.stop() }
    private let processingSound: ProcessingSound
    private var task: Task<Void, Never>?
    private var files: [URL] = []
    private var rateObserver: AnyCancellable?
    private var generation = UUID()

    init(processingSound: ProcessingSound? = nil) {
        self.processingSound = processingSound ?? ProcessingSound()
        AudioOutputManager.shared.register(player)
        rateObserver = player.publisher(for: \.rate).receive(on: RunLoop.main).sink { [weak self] in self?.playing = $0 != 0 }
    }

    func run(soundFeedback: Bool = false, _ action: @escaping @MainActor () async throws -> Void) {
        cancel()
        busy = true
        if soundFeedback { processingSound.start() }
        let id = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == id { processingSound.stop(); busy = false; task = nil } }
            do { try await MediaJobContext.$priority.withValue(.interactive) { try await action() } }
            catch is CancellationError { }
            catch {
                guard generation == id else { return }
                message = ApplicationMessageDescriptor(title: "Voice Adjustment Could Not Be Completed", message: error.localizedDescription)
            }
        }
    }

    func play(_ url: URL, asset: AVAsset? = nil) throws {
        try Task.checkCancellation()
        files.append(url)
        player.replaceCurrentItem(with: asset.map { AVPlayerItem(asset: $0) } ?? AVPlayerItem(url: url))
        processingSound.stopBeforePlayback()
        player.play()
    }

    func play(_ url: URL, asset: AVAsset? = nil, position: Double) async throws {
        try Task.checkCancellation()
        files.append(url)
        let item = asset.map { AVPlayerItem(asset: $0) } ?? AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        let end = try await item.asset.load(.duration).seconds
        let destination = position.isFinite && position < end ? max(0, position) : 0
        await player.seek(to: CMTime(seconds: destination, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
        try Task.checkCancellation()
        guard player.currentItem === item else { throw CancellationError() }
        processingSound.stopBeforePlayback()
        player.play()
    }

    func cancel() {
        processingSound.stop()
        generation = UUID()
        task?.cancel()
        task = nil
        busy = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        for url in files { try? FileManager.default.removeItem(at: url) }
        files = []
    }
}

/// The recording tools and existing narration clips share the same native controls.
struct VoiceAdjustmentControls: View {
    @Binding var settings: VoiceAdjustment
    @ObservedObject var controller: ProjectController
    @ObservedObject var work: VoiceAdjustmentWork
    var track: TimelineTrack?
    let validateTake: (VoiceAdjustment) async throws -> Void
    let applyTrack: (VoiceAdjustment) async throws -> Void
    let beforePlayback: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Voice adjustments").font(.headline).accessibilityAddTraits(.isHeader)
            HStack {
                LabeledContent("Dialogue reference In") {
                    TextField("", value: $settings.referenceStart, format: RecordingTimeFormat()).labelsHidden()
                }
                LabeledContent("Dialogue reference Out") {
                    TextField("", value: $settings.referenceEnd, format: RecordingTimeFormat()).labelsHidden()
                }
            }
            HStack {
                Button(work.playing ? "Stop playback" : "Play reference") {
                    if work.playing { work.cancel(); return }
                    beforePlayback()
                    let start = settings.referenceStart, end = settings.referenceEnd
                    work.run(soundFeedback: true) {
                        let url = try await VoiceReferenceAudio.render(project: controller.project,
                            urls: controller.resolvedMediaURLs(), start: start, end: end)
                        do { try work.play(url) }
                        catch { try? FileManager.default.removeItem(at: url); throw error }
                    }
                }
                Button("Match voice loudness to Primary Audio") {
                    beforePlayback()
                    let original = settings
                    let project = controller.project
                    work.run(soundFeedback: true) {
                        let url = try await VoiceReferenceAudio.render(project: project,
                            urls: controller.resolvedMediaURLs(), start: original.referenceStart, end: original.referenceEnd)
                        defer { try? FileManager.default.removeItem(at: url) }
                        var candidate = original
                        candidate.targetLoudness = try await VoiceAudioProcessor.measure(url)
                        try await validateTake(candidate)
                        try Task.checkCancellation()
                        guard settings == original, controller.project == project else {
                            throw AudioCaptureError.message("The voice settings or project changed during analysis. Try matching again.")
                        }
                        settings = candidate
                    }
                }
                Button("Remove match") { settings.targetLoudness = nil }
                    .disabled(settings.targetLoudness == nil)
            }
            Text(settings.targetLoudness == nil ? "Voice is not matched." : "Voice matching enabled.")
            VoiceSmoothingControls(settings: $settings)
            Slider(value: $settings.level, in: -12...12, step: 0.5) { Text("Voice level") }
                .accessibilityValue(AudioClipControlSpecification.spokenDecibels(settings.level))
                .accessibilityIdentifier("trimato.voice.level")
            Text(AudioClipControlSpecification.visibleDecibels(settings.level)).accessibilityHidden(true)
            HStack {
                Button("Reset voice adjustments") {
                    settings.targetLoudness = nil
                    settings.evenOut = false
                    settings.level = 0
                }
                if let track {
                    Button("Apply voice settings to \(track.name)") {
                        let candidate = settings
                        beforePlayback()
                        work.run(soundFeedback: true) { try await applyTrack(candidate) }
                    }
                }
            }
        }
        .disabled(work.busy)
        .onAppear { work.startKeyboard() }
        .onDisappear { work.stopKeyboard(); work.cancel() }
    }
}

struct VoiceSmoothingControls: View {
    @Binding var settings: VoiceAdjustment
    var body: some View {
        Toggle("Even out voice", isOn: $settings.evenOut).toggleStyle(.switch)
        if settings.evenOut {
            AudioValueSlider(label: "Smoothing amount", value: Binding(get: { settings.effectiveSmoothingAmount },
                set: { settings.smoothingAmount = $0 }), range: 0...100, step: 1, unit: "percent", identifier: "trimato.voice.smoothing")
        }
    }
}
