import AVFoundation
import SwiftUI

struct ContentView: View {
    @ObservedObject private var viewModel: VideoPlayerViewModel
    private let allowsFileOpening: Bool
    private let editorHeading: String?
    private let accessibilityFocusRequest: Int
    @AccessibilityFocusState private var clipPlayheadFocused: Bool
    @State private var pendingPlaybackFocus = false

    init(
        viewModel: VideoPlayerViewModel,
        allowsFileOpening: Bool = true,
        editorHeading: String? = nil,
        accessibilityFocusRequest: Int = 0
    ) {
        self.viewModel = viewModel
        self.allowsFileOpening = allowsFileOpening
        self.editorHeading = editorHeading
        self.accessibilityFocusRequest = accessibilityFocusRequest
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
        .frame(minWidth: 640, minHeight: 480)
        .background(EditorTheme.workspace)
        .tint(EditorTheme.accent)
        .preferredColorScheme(.dark)
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
        .sheet(isPresented: Binding(
            get: { viewModel.isLoadingMedia },
            set: { presented in
                if !presented { viewModel.cancelMediaLoad() }
            }
        )) {
            MediaImportView(
                filename: viewModel.mediaFilename,
                status: viewModel.mediaStatus ?? "Preparing media",
                progress: viewModel.mediaProgress,
                cancel: viewModel.cancelMediaLoad
            )
        }
        .sheet(isPresented: Binding(
            get: { viewModel.isExporting },
            set: { presented in
                if !presented, viewModel.isExporting { viewModel.cancelExport() }
            }
        )) {
            ExportProgressSheet(
                title: "Exporting Clip",
                progress: viewModel.exportProgress,
                cancel: viewModel.cancelExport
            )
        }
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
        .onAppear {
            if accessibilityFocusRequest > 0 {
                requestPlaybackControlFocus()
            }
        }
        .onChange(of: accessibilityFocusRequest) {
            requestPlaybackControlFocus()
        }
        .onChange(of: viewModel.hasMedia) {
            if viewModel.hasMedia, pendingPlaybackFocus {
                requestPlaybackControlFocus()
            }
        }
        .onDisappear {
            viewModel.closeMedia()
        }
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
                    if viewModel.isLoadingMedia {
                        if let progress = viewModel.mediaProgress {
                            ProgressView(value: progress) {
                                Text("Preparing media")
                            }
                        } else {
                            ProgressView("Preparing media")
                        }
                    } else if allowsFileOpening {
                        Button("Open File\u{2026}") { viewModel.openFile() }
                    }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 360)
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
            if viewModel.duration > 0 {
                Slider(
                    value: Binding(
                        get: { viewModel.duration > 0 ? viewModel.currentTime / viewModel.duration : 0 },
                        set: { viewModel.seek(to: $0) }
                    ),
                    in: 0...1,
                    step: viewModel.playbackFractionStep
                )
                .accessibilityLabel("Clip playhead")
                .accessibilityValue(viewModel.accessibilityTimecodeLabel)
                .accessibilityIdentifier(ClipEditorAccessibilityIdentifier.playhead)
                .accessibilityFocused($clipPlayheadFocused)
            }

            playbackControls
            markerControls
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(EditorTheme.controlSurface)
    }

    private var markerControls: some View {
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
                        : "Current playback time. Frame display is unavailable for audio-only media"
                )

                speedBadge

                HStack(spacing: 20) {
                    Button { viewModel.stepBackward() } label: {
                        Image(systemName: "backward.frame.fill").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.hasVideo)
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
                    .disabled(!viewModel.hasVideo)
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

    private func requestPlaybackControlFocus() {
        pendingPlaybackFocus = true
        guard viewModel.hasMedia else { return }
        clipPlayheadFocused = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard viewModel.hasMedia else { return }
            clipPlayheadFocused = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            guard viewModel.hasMedia else { return }
            clipPlayheadFocused = true
            pendingPlaybackFocus = false
        }
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
