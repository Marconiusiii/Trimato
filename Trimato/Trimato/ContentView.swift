import AppKit
import Combine
import AVFoundation
import SwiftUI

struct ContentView: View {
    @ObservedObject private var viewModel: VideoPlayerViewModel
    private let allowsFileOpening: Bool
    private let editorHeading: String?
    private let compact: Bool
    private let preparation: OperationProgress?
    private let isPreparingClipPreview: Bool
    @StateObject private var entryFocus = ClipEditorEntryFocus()
    @FocusState private var playheadKeyboardFocused: Bool
    @AccessibilityFocusState private var playheadVoiceOverFocused: Bool

    init(
        viewModel: VideoPlayerViewModel,
        allowsFileOpening: Bool = true,
        editorHeading: String? = nil,
        compact: Bool = false,
        preparation: OperationProgress? = nil,
        isPreparingClipPreview: Bool = false
    ) {
        self.viewModel = viewModel
        self.allowsFileOpening = allowsFileOpening
        self.editorHeading = editorHeading
        self.compact = compact
        self.preparation = preparation
        self.isPreparingClipPreview = isPreparingClipPreview
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
        .tint(EditorTheme.accent)
        .preferredColorScheme(.dark)
        .focusedObject(viewModel)
        .background(ClipEditorEntryFocusBridge(owner: entryFocus, ready: entryFocusReady))
        .onChange(of: entryFocus.request) {
            playheadKeyboardFocused = true
            playheadVoiceOverFocused = true
        }
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
        .dropDestination(for: URL.self) { urls, _ in
            guard allowsFileOpening else { return false }
            guard let url = urls.first else { return false }
            viewModel.load(url: url)
            return true
        }
        .onOpenURL { url in
            guard allowsFileOpening else { return }
            guard url.isFileURL else { return }
            viewModel.load(url: url)
        }
        .operationProgress(mediaOperation,
                           outcome: viewModel.hasMedia ? .completed : .failed)
        .operationProgress(viewModel.isExporting ? OperationProgress(
            title: "Exporting Clip", progress: viewModel.exportProgress, cancel: viewModel.cancelExport
        ) : nil, outcome: viewModel.exportErrorMessage == nil ? .completed : .failed)
        .alert("Clip Could Not Be Exported", isPresented: Binding(
            get: { viewModel.exportErrorMessage != nil },
            set: { presented in
                if !presented { viewModel.dismissExportError() }
            }
        )) {
            Button("OK") { viewModel.dismissExportError() }
        } message: {
            Text(viewModel.exportErrorMessage ?? "Trimato could not create the selected file.")
        }
        .onDisappear {
            viewModel.closeMedia()
        }
    }

    private var entryFocusReady: Bool {
        viewModel.hasMedia && viewModel.duration > 0 && mediaOperation == nil && !isPreparingClipPreview
    }

    private var mediaOperation: OperationProgress? {
        if var preparation {
            preparation.announceCompletion = false
            return preparation
        }
        guard viewModel.isLoadingMedia || viewModel.isPreparingWaveform else { return nil }
        return OperationProgress(title: "Preparing Media",
                                 progress: viewModel.isLoadingMedia ? viewModel.mediaProgress : nil,
                                 detail: viewModel.isLoadingMedia ? viewModel.mediaStatus : "Preparing audio waveform",
                                 cancel: viewModel.cancelMediaLoad, announceCompletion: false)
    }

    // MARK: - Video area

    private var canNavigateTimeline: Bool {
        viewModel.hasMedia && !viewModel.isExporting && !viewModel.isApplyingEdit
    }

    private var videoArea: some View {
        ZStack {
            Color.black
            if viewModel.hasMedia {
                if viewModel.hasVideo {
                    VideoPlayerView(player: viewModel.player)
                        .accessibilityHidden(true)
                } else {
                    AudioWaveformView(
                        samples: viewModel.waveformSamples,
                        playbackFraction: viewModel.duration > 0
                            ? viewModel.currentTime / viewModel.duration
                            : 0,
                        isLoading: viewModel.isPreparingWaveform
                    )
                }
            } else if !viewModel.isLoadingMedia {
                VStack(spacing: 16) {
                    Image(systemName: "waveform")
                        .font(.system(size: 64))
                        .foregroundStyle(.tertiary)
                    Text(viewModel.mediaStatus ?? "Open an audio or video file to begin")
                        .foregroundStyle(.secondary)
                    if allowsFileOpening {
                        Button("Open File\u{2026}") { viewModel.openFile() }
                    }
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
            Slider(
                value: Binding(
                    get: { viewModel.duration > 0 ? viewModel.currentTime / viewModel.duration : 0 },
                    set: { viewModel.seek(to: $0) }
                ),
                in: 0...1,
                step: viewModel.playbackFractionStep
            )
            .disabled(viewModel.duration <= 0)
            .accessibilityLabel("Clip playhead")
            .accessibilityValue(viewModel.accessibilityTimecodeLabel)
            .accessibilityIdentifier(ClipEditorAccessibilityIdentifier.playhead)
            .focused($playheadKeyboardFocused)
            .accessibilityFocused($playheadVoiceOverFocused)

            playbackControls
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
                        Text(viewModel.showingFrames
                             ? String(format: "%06d", viewModel.currentFrame)
                             : viewModel.displayTimecode)
                            .font(.system(.title, design: .monospaced).weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(EditorTheme.accent)
                        Text(viewModel.showingFrames ? "FRAMES" : "TIMECODE")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.hasMedia)
                .accessibilityLabel(viewModel.accessibilityTimecodeLabel)
                .accessibilityHint(
                    viewModel.hasVideo
                        ? (viewModel.showingFrames ? "Toggles to timecode" : "Toggles to frames")
                        : "Current playback time"
                )

                speedBadge

                HStack(spacing: 20) {
                    Button { viewModel.stepBackward() } label: {
                        Image(systemName: "backward.frame.fill").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.hasMedia)
                    .accessibilityLabel("Step backward one frame")

                    Button { viewModel.seekBackward() } label: {
                        Image(systemName: "gobackward.10").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.hasMedia)
                    .accessibilityLabel("Skip back 10 seconds")

                    Button { viewModel.togglePlayPause() } label: {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 30))
                            .frame(width: 38)
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.hasMedia)
                    .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

                    Button { viewModel.seekForward() } label: {
                        Image(systemName: "goforward.10").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.hasMedia)
                    .accessibilityLabel("Skip forward 10 seconds")

                    Button { viewModel.stepForward() } label: {
                        Image(systemName: "forward.frame.fill").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.hasMedia)
                    .accessibilityLabel("Step forward one frame")
                }
                .foregroundStyle(EditorTheme.accent)
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
                .foregroundStyle(.secondary)
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
            .disabled(!viewModel.canExport)

            if !viewModel.isExporting, let exportStatus = viewModel.exportStatus {
                Text(exportStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
    private var returningFromSheet = false

    mutating func sheetBegan() { returningFromSheet = true }

    mutating func becameKey() {
        if returningFromSheet { returningFromSheet = false }
        else { pending = true }
    }

    mutating func consume(ready: Bool, isKeyWindow: Bool, hasSheet: Bool) -> Bool {
        guard pending, ready, isKeyWindow, !hasSheet else { return false }
        pending = false
        return true
    }
}

@MainActor
final class ClipEditorEntryFocus: ObservableObject {
    @Published private(set) var request = 0
    private var policy = ClipEditorEntryFocusPolicy()
    private weak var window: NSWindow?
    private var ready = false
    private var observers: [NSObjectProtocol] = []
    private var delivery: Task<Void, Never>?

    func update(ready: Bool, window: NSWindow?) {
        self.ready = ready
        attach(window)
        schedule()
    }

    func attach(_ window: NSWindow?) {
        guard self.window !== window else { return }
        disconnect()
        self.window = window
        policy = ClipEditorEntryFocusPolicy()
        guard let window else { return }
        observe(NSWindow.didBecomeKeyNotification, window: window) { owner in
            owner.policy.becameKey()
            owner.schedule()
        }
        observe(NSWindow.willBeginSheetNotification, window: window) { owner in
            owner.policy.sheetBegan()
            owner.delivery?.cancel()
            owner.delivery = nil
        }
        observe(NSWindow.didEndSheetNotification, window: window) { $0.schedule() }
        schedule()
    }

    private func observe(_ name: Notification.Name, window: NSWindow,
                         action: @escaping @MainActor (ClipEditorEntryFocus) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
            [weak self] _ in
            // These AppKit window notifications are delivered on the main thread.
            MainActor.assumeIsolated { if let self { action(self) } }
        })
    }

    private func schedule() {
        guard delivery == nil else { return }
        delivery = Task { @MainActor [weak self] in
            // Let the native window event and SwiftUI's readiness updates finish.
            // There are no timed retries or requests after this entry is consumed.
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.delivery = nil
            guard let window = self.window,
                  self.policy.consume(ready: self.ready, isKeyWindow: window.isKeyWindow,
                                      hasSheet: window.attachedSheet != nil) else { return }
            self.request += 1
        }
    }

    func disconnect() {
        delivery?.cancel()
        delivery = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        window = nil
    }
}

private struct ClipEditorEntryFocusBridge: NSViewRepresentable {
    let owner: ClipEditorEntryFocus
    let ready: Bool

    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.owner = owner
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: Anchor, context: Context) { owner.update(ready: ready, window: view.window) }

    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.owner?.disconnect() }

    final class Anchor: NSView {
        weak var owner: ClipEditorEntryFocus?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            owner?.attach(window)
        }
    }
}
