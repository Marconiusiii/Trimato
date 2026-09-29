import AppKit
import Combine
import AVFoundation
import SwiftUI

struct ContentView: View {
    @AppStorage(AppPreferenceKey.accentColor) private var accentChoice = EditorAccent.teal
    @ObservedObject private var viewModel: VideoPlayerViewModel
    private let editorHeading: String?
    private let compact: Bool
    private let isPreparingSource: Bool
    private let isPreparingClipPreview: Bool
    private let entryCompleted: () -> Void
    @State private var showingSilenceTrim = false
    @StateObject private var entryFocus = ClipEditorEntryFocus()

    init(
        viewModel: VideoPlayerViewModel,
        editorHeading: String? = nil,
        compact: Bool = false,
        isPreparingSource: Bool = false,
        isPreparingClipPreview: Bool = false,
        entryCompleted: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.editorHeading = editorHeading
        self.compact = compact
        self.isPreparingSource = isPreparingSource
        self.isPreparingClipPreview = isPreparingClipPreview
        self.entryCompleted = entryCompleted
    }

    var body: some View {
        VStack(spacing: 0) {
            if let editorHeading {
                Text(editorHeading)
                    .font(.title2)
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(EditorTheme.controlSurface)
            }
            videoArea
            controlsArea
        }
        .frame(minWidth: 640, minHeight: compact ? 280 : 480)
        .background(EditorTheme.workspace)
        .editorAppearance()
        .focusedObject(viewModel)
        .toolbar {
            ToolbarItemGroup {
                Button { viewModel.goToStart() } label: {
                    Label("Go to start", systemImage: "backward.end.fill")
                }
                .help("Go to start")
                .disabled(!canNavigateTimeline)

                Button { viewModel.goToPreviousTimelinePoint() } label: {
                    Label("Previous timeline point", systemImage: "chevron.left.2")
                }
                .help("Previous timeline point")
                .disabled(!canNavigateTimeline)

                Button { viewModel.goToNextTimelinePoint() } label: {
                    Label("Next timeline point", systemImage: "chevron.right.2")
                }
                .help("Next timeline point")
                .disabled(!canNavigateTimeline)

                Button { viewModel.goToEnd() } label: {
                    Label("Go to end", systemImage: "forward.end.fill")
                }
                .help("Go to end")
                .disabled(!canNavigateTimeline)
            }
        }
        .sheet(isPresented: $showingSilenceTrim) { TrimSilencesView(viewModel: viewModel) }
        .operationProgress(viewModel.isExporting ? OperationProgress(
            title: "Exporting Clip", progress: viewModel.exportProgress, cancel: viewModel.cancelExport
        ) : nil, outcome: viewModel.exportErrorMessage == nil ? .completed : .failed)
        .applicationMessage(viewModel.exportErrorMessage.map {
            ApplicationMessageDescriptor(title: "Clip Could Not Be Exported", message: $0)
        }) {
            viewModel.dismissExportError()
        }
        .onDisappear {
            viewModel.closeMedia()
        }
    }

    private var entryFocusReady: Bool {
        viewModel.hasMedia && viewModel.duration > 0 && !isPreparingSource &&
            !viewModel.isLoadingMedia && !isPreparingClipPreview
    }

    // MARK: - Video area

    private var canNavigateTimeline: Bool {
        viewModel.hasMedia && !viewModel.isExporting && !viewModel.isApplyingEdit
    }

    private var videoArea: some View {
        ZStack {
            (viewModel.hasMedia && viewModel.hasVideo ? Color.black : EditorTheme.workspace)
            if viewModel.hasMedia {
                if viewModel.hasVideo {
                    VideoPlayerView(player: viewModel.player)
                        .accessibilityHidden(true)
                } else if viewModel.showsAudioWaveforms {
                    AudioWaveformView(samples: viewModel.waveformSamples, isLoading: viewModel.isPreparingWaveform)
                }
            } else if !viewModel.isLoadingMedia {
                VStack(spacing: 16) {
                    Image(systemName: "waveform")
                        .font(.system(size: 64))
                        .foregroundStyle(EditorTheme.secondaryText)
                    Text(viewModel.mediaStatus ?? "Open an audio or video file to begin")
                        .foregroundStyle(EditorTheme.secondaryText)
                }
            }
        }
        .frame(minWidth: 640, minHeight: compact ? 120 : 240, maxHeight: compact ? 240 : .infinity)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(EditorTheme.separator)
                .frame(height: 1)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Controls

    private var controlsArea: some View {
        VStack(spacing: 10) {
            ClipLivePlayhead(clock: viewModel.playbackClock, duration: viewModel.duration,
                step: viewModel.playbackFractionStep,
                spokenValue: { fraction in
                    viewModel.spokenTime(CMTime(seconds: fraction * viewModel.duration, preferredTimescale: 600_000))
                }, isMoving: { viewModel.isPlayheadMoving }, seek: viewModel.seek,
                entry: ClipEditorEntryRequest(owner: entryFocus, ready: entryFocusReady,
                    willEnter: viewModel.refreshAccessibilityValueForFocus, completed: entryCompleted))
            .disabled(viewModel.duration <= 0)
            .tint(EditorTheme.playhead)

            playbackControls
            Button("Trim Silences…") { showingSilenceTrim = true }
                .disabled(!viewModel.canTrimSilences)
            if !compact { ClipMarkerControlsView(viewModel: viewModel) }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(EditorTheme.controlSurface)
    }

    private var playbackControls: some View {
        GroupBox {
            VStack(spacing: 8) {
                Button { viewModel.toggleTimecodeDisplay() } label: {
                    VStack(spacing: 2) {
                        ClipLiveTimecode(clock: viewModel.playbackClock, showingFrames: viewModel.showingFrames)
                            .font(.system(.title, design: .monospaced).weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(EditorTheme.accent(for: accentChoice))
                        Text(viewModel.showingFrames ? "Frames" : "Timecode")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(EditorTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.hasMedia)
                .accessibilityLabel("Clip timecode")
                .accessibilityValue(viewModel.accessibilityTimecodeLabel)
                .accessibilityHint(
                    viewModel.hasVideo
                        ? (viewModel.showingFrames ? "Toggles to timecode" : "Toggles to frames")
                        : "Current playback time"
                )

                speedBadge

                HStack(spacing: EditorTheme.actionSpacing) {
                    Button { viewModel.stepBackward() } label: {
                        Image(systemName: "backward.frame.fill").font(.system(size: 17, weight: .medium)).frame(width: 28, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.hasMedia)
                    .accessibilityLabel("Step backward one frame")

                    Button { viewModel.seekBackward() } label: {
                        Image(systemName: "gobackward.10").font(.system(size: 17, weight: .medium)).frame(width: 28, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.hasMedia)
                    .accessibilityLabel("Skip back 10 seconds")

                    Button { viewModel.togglePlayPause() } label: {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .frame(width: 32, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.hasMedia)
                    .accessibilityLabel(viewModel.waitingForClipPreview ? "Cancel pending playback" : viewModel.isPlaying ? "Pause" : "Play")

                    Button { viewModel.seekForward() } label: {
                        Image(systemName: "goforward.10").font(.system(size: 17, weight: .medium)).frame(width: 28, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.hasMedia)
                    .accessibilityLabel("Skip forward 10 seconds")

                    Button { viewModel.stepForward() } label: {
                        Image(systemName: "forward.frame.fill").font(.system(size: 17, weight: .medium)).frame(width: 28, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.hasMedia)
                    .accessibilityLabel("Step forward one frame")
                }
                .foregroundStyle(EditorTheme.accent(for: accentChoice))
                .disabled(!viewModel.hasMedia || viewModel.isExporting || viewModel.isApplyingEdit)
                .padding(.bottom, 8)
            }
            .padding(.top, 4)
        } label: {
            Text("Playback").accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback")
        .accessibilityIdentifier("trimato.clip-editor.playback")
    }

    @ViewBuilder
    private var speedBadge: some View {
        if viewModel.isPlaying, viewModel.playbackRate != 1.0 {
            Text(viewModel.playbackRate < 0
                 ? "← \(Int(abs(viewModel.playbackRate)))×"
                 : "\(Int(viewModel.playbackRate))× →")
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(EditorTheme.secondaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(EditorTheme.raisedSurface, in: Capsule())
                .accessibilityHidden(true)
        }
    }
}

struct ClipExportControlsView: View {
    @ObservedObject var viewModel: VideoPlayerViewModel

    var body: some View {
        VStack(spacing: 6) {
            Button("Export Clip\u{2026}") {
                viewModel.exportTrimmedClip()
            }
            .buttonStyle(.borderedProminent)
            .editorPrimaryAction()
            .disabled(!viewModel.canExport)

            if !viewModel.isExporting, let exportStatus = viewModel.exportStatus {
                Text(exportStatus)
                    .font(.caption)
                    .foregroundStyle(EditorTheme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct ClipMarkerControlsView: View {
    @ObservedObject var viewModel: VideoPlayerViewModel
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Mark In") { viewModel.markIn() }
                    Text("In: \(viewModel.inMarkerDisplay)")
                        .monospacedDigit()
                    Button("Clear In") { viewModel.clearIn() }
                        .disabled(viewModel.inMarker == nil)
                }
                HStack {
                    Button("Mark Out") { viewModel.markOut() }
                    Text("Out: \(viewModel.outMarkerDisplay)")
                        .monospacedDigit()
                    Button("Clear Out") { viewModel.clearOut() }
                        .disabled(viewModel.outMarker == nil)
                }

                Button("Delete Selection") { viewModel.deleteSelection() }
                    .disabled(!viewModel.canDeleteSelection)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            Text("Markers").accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(!viewModel.hasMedia || viewModel.isExporting || viewModel.isApplyingEdit)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Markers")
        .accessibilityIdentifier("trimato.clip-editor.markers")
    }

}

/// Entry focus is a single pending request. Sheets may delay it, but dismissing
/// later dialogs must not create a new request while the user is editing.
nonisolated struct ClipEditorEntryFocusPolicy {
    private(set) var pending = true

    mutating func consume(ready: Bool, isKeyWindow: Bool, hasSheet: Bool) -> Bool {
        guard pending, ready, isKeyWindow, !hasSheet else { return false }
        pending = false
        return true
    }
}

@MainActor
struct ClipEditorEntryRequest {
    let owner: ClipEditorEntryFocus
    let ready: Bool
    let willEnter: () -> Void
    let completed: () -> Void
}

@MainActor
final class ClipEditorEntryFocus: ObservableObject {
    private var policy = ClipEditorEntryFocusPolicy()
    private weak var window: NSWindow?
    private weak var slider: NativePlayheadSlider.PlayheadSlider?
    private var ready = false
    private var willEnter: (() -> Void)?
    private var completed: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var delivery: Task<Void, Never>?
    private let isWindowAvailable: @MainActor (NSWindow) -> Bool

    init(isWindowAvailable: @escaping @MainActor (NSWindow) -> Bool = {
        $0.isKeyWindow && NSApp?.isActive == true && NSApp?.modalWindow == nil
    }) {
        self.isWindowAvailable = isWindowAvailable
    }

    func update(_ request: ClipEditorEntryRequest, slider: NativePlayheadSlider.PlayheadSlider) {
        if ready != request.ready {
            ClipEntryDiagnostics.record("entry.ready=\(request.ready) \(ClipEntryDiagnostics.window(slider.window))")
        }
        ready = request.ready
        self.slider = slider
        willEnter = request.willEnter
        completed = request.completed
        attach(slider.window)
        schedule()
    }

    func attach(_ window: NSWindow?) {
        guard self.window !== window else { return }
        cancelDelivery()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        ClipEntryDiagnostics.record("entry.attach \(ClipEntryDiagnostics.window(window))")
        self.window = window
        policy = ClipEditorEntryFocusPolicy()
        guard let window else { return }
        observe(NSWindow.didBecomeKeyNotification, object: window) { $0.schedule() }
        observe(NSWindow.willBeginSheetNotification, object: window) { $0.cancelDelivery() }
        observe(NSWindow.didEndSheetNotification, object: window) { $0.schedule() }
        observe(NSApplication.didBecomeActiveNotification, object: nil) { $0.schedule() }
        schedule()
    }

    private func observe(_ name: Notification.Name, object: AnyObject?,
                         action: @escaping @MainActor (ClipEditorEntryFocus) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        })
    }

    private func schedule() {
        guard policy.pending, delivery == nil else { return }
        delivery = Task { @MainActor [weak self] in
            // Run outside the representable update and native window callbacks.
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.delivery = nil
            guard self.policy.pending, self.ready,
                  let slider = self.slider, let window = self.window,
                  slider.window === window, self.isWindowAvailable(window),
                  window.attachedSheet == nil, slider.isEnabled, slider.acceptsFirstResponder else { return }
            ClipEntryDiagnostics.record("entry.willEnter \(ClipEntryDiagnostics.window(window))")
            self.willEnter?()
            if window.firstResponder !== slider {
                ClipEntryDiagnostics.record("entry.requestFocus target=\(ClipEntryDiagnostics.identity(slider)) \(ClipEntryDiagnostics.window(window))")
                guard window.makeFirstResponder(slider) else {
                    ClipEntryDiagnostics.record("entry.requestRejected")
                    return
                }
            }
            // AppKit can report success while choosing the window instead of the requested view.
            guard window.firstResponder === slider,
                  self.policy.consume(ready: self.ready, isKeyWindow: true, hasSheet: false) else { return }
            ClipEntryDiagnostics.record("entry.completed \(ClipEntryDiagnostics.window(window))")
            ClipEntryDiagnostics.snapshot(slider)
            self.completed?()
        }
    }

    private func cancelDelivery() {
        delivery?.cancel()
        delivery = nil
    }

    func disconnect(slider: NativePlayheadSlider.PlayheadSlider) {
        guard self.slider === slider else { return }
        cancelDelivery()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        window = nil
        self.slider = nil
        willEnter = nil
        completed = nil
    }
}

private struct ClipLiveTimecode: View {
    @AppStorage(AppPreferenceKey.timecodeStyle) private var storedStyle = ""
    @AppStorage(AppPreferenceKey.precisionTimecode) private var precisionTimecode = true
    @ObservedObject var clock: ClipPlaybackClock
    let showingFrames: Bool
    var body: some View {
        Text(AppPreferences.displayTimecode(seconds: clock.time, frame: clock.frame, milliseconds: precisionTimecode,
            style: showingFrames ? .frames : (TimecodeStyle(rawValue: storedStyle) ?? AppPreferences.timecodeStyle)))
    }
}

private struct ClipLivePlayhead: View {
    @AppStorage(AppPreferenceKey.timecodeFeedback) private var feedback = TimecodeFeedback.whenStopped
    @ObservedObject var clock: ClipPlaybackClock
    let duration: Double
    let step: Double
    let spokenValue: (Double) -> String
    let isMoving: () -> Bool
    let seek: (Double) -> Void
    let entry: ClipEditorEntryRequest
    var body: some View {
        NativePlayheadSlider(value: Binding(get: { duration > 0 ? clock.time / duration : 0 }, set: seek),
            step: step, label: "Clip playhead", identifier: ClipEditorAccessibilityIdentifier.playhead,
            spokenValue: spokenValue, feedback: feedback, isMoving: isMoving, clipEntry: entry)
    }
}
