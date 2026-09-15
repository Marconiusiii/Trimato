import AVFoundation
import SwiftUI

struct TrimSilencesView: View {
    @ObservedObject var viewModel: VideoPlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    @State private var settings = SilenceTrimSettings()
    @State private var markedOnly = false
    @State private var busy = false
    @State private var message = ""
    @State private var plan: SilenceTrimPlan?
    @State private var baseline: ClipEditTimeline?
    @State private var previewAsset: AVAsset?
    @State private var task: Task<Void, Never>?
    @State private var player = AVPlayer()
    @State private var playing = false
    @State private var previewStart = CMTime.zero

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Trim Silences").font(EditorTheme.dialogTitle).accessibilityAddTraits(.isHeader)
            Form {
                Toggle("Only between In and Out", isOn: $markedOnly)
                    .disabled(viewModel.inMarker == nil || viewModel.outMarker == nil)
                AudioValueSlider(label: "Quiet level", value: $settings.thresholdDB,
                    range: -90...0, step: 1, unit: "dB", identifier: "trimato.silence.quiet-level",
                    preservesStep: true, spokenValue: { "\($0.formatted(.number.precision(.fractionLength(0)))) dB" })
                AudioValueSlider(label: "Shortest pause to trim", value: $settings.minimumPause,
                    range: 0.05...max(10, settings.minimumPause.rounded(.up) + 1), step: 0.05,
                    unit: "seconds", identifier: "trimato.silence.shortest-pause",
                    preservesStep: true, spokenValue: Self.seconds)
                AudioValueSlider(label: "Keep this much of each pause", value: $settings.retainedPause,
                    range: 0...max(10, settings.retainedPause.rounded(.up) + 1), step: 0.05,
                    unit: "seconds", identifier: "trimato.silence.retained-pause",
                    preservesStep: true, spokenValue: Self.seconds)
            }.formStyle(.columns)
                .disabled(busy)
            Button(busy ? "Cancel Search" : "Find Pauses") {
                if busy { cancel() } else { analyze() }
            }
            if busy { ProgressView("Finding pauses and preparing preview…") }
            if !message.isEmpty {
                Text(message).fixedSize(horizontal: false, vertical: true)
            }
            if viewModel.hasVideo, previewAsset != nil {
                VideoPlayerView(player: player)
                    .frame(height: 180)
                    .accessibilityHidden(true)
            }
            Button(playing ? "Pause Preview" : "Play Preview") {
                if playing { player.pause() }
                else {
                    if player.currentTime().seconds >= (player.currentItem?.forwardPlaybackEndTime.seconds ?? .infinity) - 0.02 {
                        player.seek(to: previewStart)
                    }
                    player.play()
                }
                playing.toggle()
            }.disabled(previewAsset == nil || busy)
            HStack(spacing: EditorTheme.actionSpacing) {
                Button("Help") {
                    if let error = TrimatoHelp.open(.trimSilences) { message = error }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Trim Pauses") { apply() }
                    .buttonStyle(.borderedProminent)
                    .editorPrimaryAction()
                    .disabled(busy || (plan?.removedCount ?? 0) == 0 || previewAsset == nil)
            }
        }
        .padding(EditorTheme.dialogPadding)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            viewModel.player.pause()
            markedOnly = viewModel.inMarker != nil && viewModel.outMarker != nil
        }
        .onChange(of: settings) { invalidate() }
        .onChange(of: markedOnly) { invalidate() }
        .onChange(of: message) { _, result in
            guard !result.isEmpty, !AudioCaptureSession.suppressesAnnouncements,
                  let application = NSApp else { return }
            NSAccessibility.post(
                element: application,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: result,
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue
                ]
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            if notification.object as? AVPlayerItem === player.currentItem { playing = false }
        }
        .onDisappear { task?.cancel(); player.pause(); player.replaceCurrentItem(with: nil) }
    }

    nonisolated private static func seconds(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...2)))) seconds"
    }

    private func invalidate() {
        player.pause(); playing = false; plan = nil; previewAsset = nil; baseline = nil
        player.replaceCurrentItem(with: nil)
        message = ""
    }

    private func cancel() {
        task?.cancel(); task = nil; busy = false
        invalidate()
        message = "Search cancelled. The clip is unchanged."
    }

    private func analyze() {
        invalidate(); busy = true
        task = Task { @MainActor in
            do {
                let (url, timeline, selection, asset) = try viewModel.silenceTrimInput(markedOnly: markedOnly)
                let result = try await ClipSilenceTrimmer.analyze(url: url, timeline: timeline,
                    selection: selection, settings: settings,
                    frameRate: viewModel.silenceTrimFrameRate)
                try Task.checkCancellation()
                let preview = try await EditedCompositionBuilder.playbackAsset(asset: asset, sourceRanges: result.sourceRanges)
                try Task.checkCancellation()
                baseline = timeline; plan = result; previewAsset = preview
                let item = AVPlayerItem(asset: preview)
                previewStart = result.remap(selection.start)
                item.forwardPlaybackEndTime = result.remap(selection.end)
                player.replaceCurrentItem(with: item)
                await player.seek(to: previewStart, toleranceBefore: .zero, toleranceAfter: .zero)
                try Task.checkCancellation()
                if result.removedCount == 0 {
                    message = "No pauses to trim were found with these settings."
                } else {
                    let pauses = result.removedCount == 1 ? "1 pause" : "\(result.removedCount) pauses"
                    let seconds = result.removedSeconds.formatted(.number.precision(.fractionLength(0...2)))
                    message = "Found \(pauses). Trimming will make this clip \(seconds) seconds shorter."
                }
                busy = false; task = nil
            } catch is CancellationError {
                // Cancellation owns its status; a replaced task must not alter a new analysis.
            } catch {
                guard !Task.isCancelled else { return }
                message = error.localizedDescription; busy = false; task = nil
            }
        }
    }

    private func apply() {
        guard let plan, let baseline, let previewAsset else { return }
        do {
            try viewModel.applySilenceTrim(plan, previewAsset: previewAsset,
                expectedTimeline: baseline, undoManager: undoManager ?? NSApp.keyWindow?.sheetParent?.undoManager ?? NSApp.keyWindow?.undoManager)
            dismiss()
        } catch { message = error.localizedDescription }
    }
}
