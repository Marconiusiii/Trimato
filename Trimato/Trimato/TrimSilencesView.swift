import AVFoundation
import SwiftUI

struct TrimSilencesView: View {
    @ObservedObject var viewModel: VideoPlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    @State private var settings = SilenceTrimSettings()
    @State private var markedOnly = false
    @State private var busy = false
    @State private var message = "Choose the quiet level and pause lengths, then analyze the clip."
    @State private var plan: SilenceTrimPlan?
    @State private var baseline: ClipEditTimeline?
    @State private var previewAsset: AVAsset?
    @State private var task: Task<Void, Never>?
    @State private var player = AVPlayer()
    @State private var playing = false
    @State private var previewStart = CMTime.zero

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Trim Silences").font(.title2).accessibilityAddTraits(.isHeader)
                    if viewModel.hasVideo {
                        Text("Trimming silences removes matching video and audio, creating jump cuts. Preview the result before applying.")
                    }
                    Form {
                        Toggle("Analyze marked selection only", isOn: $markedOnly)
                            .disabled(viewModel.inMarker == nil || viewModel.outMarker == nil)
                        TextField("Silence threshold (dB)", value: $settings.thresholdDB, format: .number)
                        TextField("Minimum pause (seconds)", value: $settings.minimumPause, format: .number)
                        TextField("Pause to retain (seconds)", value: $settings.retainedPause, format: .number)
                    }.disabled(busy)
                    Text("Audio below the threshold for at least the minimum pause qualifies. Retained silence is shared between both sides of each cut.")
                    Text(message).fixedSize(horizontal: false, vertical: true)
                    if viewModel.hasVideo, previewAsset != nil {
                        VideoPlayerView(player: player)
                            .frame(height: 180)
                            .accessibilityHidden(true)
                    }
                    if busy { ProgressView("Analyzing and preparing preview…") }
                    HStack {
                        Button(busy ? "Cancel Analysis" : "Analyze") {
                            if busy { cancel() } else { analyze() }
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
                    }
                    Text("Apply keeps the edits in this clip. Update Clip saves them to the timeline and may move later clips earlier on the same track. Other tracks are not shortened automatically.")
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply") { apply() }
                    .disabled(busy || (plan?.removedCount ?? 0) == 0 || previewAsset == nil)
            }
        }
        .padding(20).frame(width: 520, height: viewModel.hasVideo ? 620 : 460)
        .onAppear {
            viewModel.player.pause()
            markedOnly = viewModel.inMarker != nil && viewModel.outMarker != nil
        }
        .onChange(of: settings) { invalidate() }
        .onChange(of: markedOnly) { invalidate() }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            if notification.object as? AVPlayerItem === player.currentItem { playing = false }
        }
        .onDisappear { task?.cancel(); player.pause(); player.replaceCurrentItem(with: nil) }
    }

    private func invalidate() {
        player.pause(); playing = false; plan = nil; previewAsset = nil; baseline = nil
        player.replaceCurrentItem(with: nil)
        message = "Analyze the clip with these settings."
    }

    private func cancel() {
        task?.cancel(); task = nil; busy = false
        invalidate()
        message = "Analysis cancelled. No changes were applied."
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
                message = "\(result.removedCount) pauses found. \(String(format: "%.2f", result.removedSeconds)) seconds would be removed. Preview uses the source media before audio effects and filters."
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
