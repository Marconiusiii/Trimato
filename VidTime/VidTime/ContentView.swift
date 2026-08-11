import AVFoundation
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = VideoPlayerViewModel()

    var body: some View {
        VStack(spacing: 0) {
            videoArea
            controlsArea
        }
        .frame(minWidth: 640, minHeight: 480)
        .background(EditorTheme.workspace)
        .tint(EditorTheme.accent)
        .preferredColorScheme(.dark)
        .focusedObject(viewModel)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            viewModel.load(url: url)
            return true
        }
        .onOpenURL { url in
            guard url.isFileURL else { return }
            viewModel.load(url: url)
        }
    }

    // MARK: - Video area

    private var videoArea: some View {
        ZStack {
            Color.black
            VideoPlayerView(player: viewModel.player)
            if !viewModel.hasVideo {
                VStack(spacing: 16) {
                    Image(systemName: "film")
                        .font(.system(size: 64))
                        .foregroundStyle(.tertiary)
                    Text(viewModel.mediaStatus ?? "Open a video file to begin")
                        .foregroundStyle(.secondary)
                    if viewModel.isLoadingMedia {
                        if let progress = viewModel.mediaProgress {
                            ProgressView(value: progress) {
                                Text("Preparing video")
                            }
                        } else {
                            ProgressView("Preparing video")
                        }
                    } else {
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
                    in: 0...1
                )
                // Hidden from VoiceOver: SwiftUI posts NSAccessibilityValueChangedNotification
                // every time the bound value updates (60×/sec during playback), causing VoiceOver
                // to announce the percentage on every tick regardless of focus.
                .accessibilityHidden(true)
            }

            // Timecode / frame toggle button.
            //
            // The spoken timecode is put in .accessibilityLabel (NSAccessibilityTitleAttribute).
            // macOS VoiceOver does NOT auto-announce title-attribute changes the way it does
            // value-attribute changes (.accessibilityValue triggers NSAccessibilityValueChangedNotification,
            // causing an earcon per update). The label is read only when VoiceOver focuses this element.
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
                .accessibilityHidden(true)  // inner text hidden; button owns all AX content
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.hasVideo)
            .accessibilityLabel(viewModel.accessibilityTimecodeLabel)
            .accessibilityHint(viewModel.showingFrames ? "Toggles to timecode" : "Toggles to frames")

            markerControls
            timelineControls

            speedBadge

            // Transport controls — all fully accessible to VoiceOver.
            // Keyboard shortcuts (Space, arrows, J/K/L) go through NSEvent monitor and do NOT
            // activate these buttons, so VoiceOver will not speak during keyboard interaction.
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
                .disabled(!viewModel.hasVideo)
                .accessibilityLabel("Skip back 10 seconds")

                Button { viewModel.togglePlayPause() } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30))
                        .frame(width: 38)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.hasVideo)
                .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

                Button { viewModel.seekForward() } label: {
                    Image(systemName: "goforward.10").font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.hasVideo)
                .accessibilityLabel("Skip forward 10 seconds")

                Button { viewModel.stepForward() } label: {
                    Image(systemName: "forward.frame.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.hasVideo)
                .accessibilityLabel("Step forward one frame")
            }
            .foregroundStyle(EditorTheme.accent)
            .padding(.bottom, 8)

            Button("Export Trimmed Clip\u{2026}") {
                viewModel.exportTrimmedClip()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canExport)

            if viewModel.isExporting {
                HStack {
                    if let progress = viewModel.exportProgress {
                        ProgressView(value: progress) {
                            Text("Exporting trimmed clip")
                        }
                    } else {
                        ProgressView("Exporting trimmed clip")
                    }
                    Button("Cancel Export") { viewModel.cancelExport() }
                }
            } else if let exportStatus = viewModel.exportStatus {
                Text(exportStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(EditorTheme.controlSurface)
    }

    private var markerControls: some View {
        VStack(spacing: 6) {
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
        }
        .disabled(!viewModel.hasVideo || viewModel.isExporting)
    }

    private var timelineControls: some View {
        HStack {
            Button("Start") { viewModel.goToStart() }
            Button("Previous Point") { viewModel.goToPreviousTimelinePoint() }
            Button("Next Point") { viewModel.goToNextTimelinePoint() }
            Button("End") { viewModel.goToEnd() }
        }
        .disabled(!viewModel.hasVideo || viewModel.isExporting)
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

#Preview {
    ContentView()
}
