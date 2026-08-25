import AppKit
import SwiftUI

struct EditorWorkspaceView: View {
    @StateObject private var controller: ProjectController
    @StateObject private var clipEditorWindows: ClipEditorWindowCoordinator
    @StateObject private var projectWindowSaveCoordinator: ProjectWindowSaveCoordinator

    init(document: ProjectDocument) {
        let controller = ProjectController(document: document)
        _controller = StateObject(wrappedValue: controller)
        _clipEditorWindows = StateObject(wrappedValue: ClipEditorWindowCoordinator(controller: controller))
        _projectWindowSaveCoordinator = StateObject(
            wrappedValue: ProjectWindowSaveCoordinator(projectDocument: document)
        )
    }

    var body: some View {
        HSplitView {
            MacEditorPane("Project Source") {
                ProjectBrowserView(
                    controller: controller,
                    openClipEditor: clipEditorWindows.open
                )
            }
                .frame(minWidth: 210, idealWidth: 260, maxWidth: 360)

            VSplitView {
                MacEditorPane("Editor") {
                    ProjectViewerView(controller: controller)
                }
                .frame(minHeight: 360)

                HSplitView {
                    MacEditorPane("Project Timeline") {
                        ProjectTimelineView(
                            controller: controller,
                            openClipEditor: clipEditorWindows.open
                        )
                    }
                        .frame(minWidth: 460)
                    MacEditorPane("Inspector") {
                        ClipInspectorView(controller: controller)
                    }
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
                }
                .frame(minHeight: 240)
            }
        }
        .frame(minWidth: 1_020, minHeight: 720)
        .background(EditorTheme.workspace)
        .background(ProjectWindowSaveBridge(saveCoordinator: projectWindowSaveCoordinator))
        .preferredColorScheme(.dark)
        .focusedObject(controller)
        .handlesTrimatoMediaOpening()
        .onAppear {
            ExternalMediaOpenCoordinator.shared.register(
                controller: controller,
                openClipEditor: { [weak clipEditorWindows] selection in
                    clipEditorWindows?.open(selection)
                }
            )
        }
        .onDisappear {
            ExternalMediaOpenCoordinator.shared.unregister(controller: controller)
        }
        .sheet(isPresented: $controller.isShowingProjectSettings) {
            ProjectCreationView(controller: controller) {
                controller.isShowingProjectSettings = false
            }
        }
        .alert(item: $controller.presentedError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

}

private struct ProjectViewerView: View {
    @ObservedObject var controller: ProjectController
    @StateObject private var viewModel = ProjectPlayerViewModel()

    var body: some View {
        VStack(spacing: 0) {
            videoArea
            controlsArea
        }
        .background(ProjectPlaybackKeyMonitor(viewModel: viewModel))
        .focusedObject(viewModel)
        .onAppear { prepare() }
        .onChange(of: controller.project) { _ in prepare() }
        .onChange(of: controller.timelinePlayhead) { time in
            guard abs(viewModel.currentTime.seconds - time.seconds) > 0.02 else { return }
            viewModel.seek(to: time)
        }
        .onChange(of: viewModel.currentTime) { time in
            if viewModel.isPlaying { controller.timelinePlayhead = time }
        }
        .alert("Project Preview Failed", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { presented in if !presented { viewModel.clearError() } }
        )) {
            Button("OK") { viewModel.clearError() }
        } message: {
            Text(viewModel.errorMessage ?? "The project preview could not be prepared.")
        }
    }

    private func prepare() {
        viewModel.prepare(project: controller.project, mediaURLs: controller.resolvedMediaURLs())
    }

    private var videoArea: some View {
        ZStack {
            Color.black
            VideoPlayerView(player: viewModel.player)
            if controller.project.primaryTimeline.isEmpty {
                Text("Add a clip to the project timeline")
                    .foregroundStyle(.secondary)
            } else if viewModel.isPreparing {
                ProgressView("Preparing Project Preview")
                    .padding()
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(EditorTheme.separator)
                .frame(height: 1)
                .accessibilityHidden(true)
        }
    }

    private var controlsArea: some View {
        VStack(spacing: 10) {
            if viewModel.duration > .zero {
                Slider(
                    value: Binding(
                        get: { viewModel.playbackFraction },
                        set: { viewModel.seek(toFraction: $0) }
                    ),
                    in: 0...1
                )
                .accessibilityHidden(true)
            }

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
            .disabled(!viewModel.canControlPlayback)
            .accessibilityLabel(viewModel.accessibilityTimecodeLabel)
            .accessibilityHint(viewModel.showingFrames ? "Toggles to timecode" : "Toggles to frames")

            if viewModel.isPlaying, viewModel.playbackRate != 1 {
                Text(viewModel.playbackRate < 0
                     ? "\(Int(abs(viewModel.playbackRate))) times backward"
                     : "\(Int(viewModel.playbackRate)) times forward")
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(EditorTheme.raisedSurface, in: Capsule())
                    .accessibilityHidden(true)
            }

            HStack(spacing: 20) {
                Button { viewModel.stepBackward() } label: {
                    Image(systemName: "backward.frame.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Step backward one frame")

                Button { viewModel.togglePlayback() } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30))
                        .frame(width: 38)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

                Button { viewModel.stepForward() } label: {
                    Image(systemName: "forward.frame.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Step forward one frame")
            }
            .foregroundStyle(EditorTheme.accent)
            .disabled(!viewModel.canControlPlayback)

            if controller.isExporting {
                if let progress = controller.exportProgress {
                    ProgressView(value: progress) { Text("Exporting Project") }
                        .accessibilityHidden(true)
                } else {
                    ProgressView("Exporting Project")
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(EditorTheme.controlSurface)
    }
}

private struct ProjectPlaybackKeyMonitor: NSViewRepresentable {
    let viewModel: ProjectPlayerViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.viewModel = viewModel
    }

    final class Coordinator {
        var viewModel: ProjectPlayerViewModel
        weak var hostView: NSView?
        private var monitor: Any?

        init(viewModel: ProjectPlayerViewModel) {
            self.viewModel = viewModel
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard event.window === hostView?.window,
                  viewModel.canControlPlayback,
                  NSApp.modalWindow == nil,
                  !isEditingText(in: event.window) else { return event }

            let commandSet: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
            let modifiers = event.modifierFlags.intersection(commandSet)
            let unmodified = modifiers.isEmpty

            switch event.type {
            case .keyDown:
                if modifiers == .command {
                    switch event.keyCode {
                    case 123:
                        if !event.isARepeat { viewModel.goToPreviousEdit() }
                        return nil
                    case 124:
                        if !event.isARepeat { viewModel.goToNextEdit() }
                        return nil
                    case 126:
                        if !event.isARepeat { viewModel.goToStart() }
                        return nil
                    case 125:
                        if !event.isARepeat { viewModel.goToEnd() }
                        return nil
                    default:
                        return event
                    }
                }
                guard unmodified else { return event }
                switch event.keyCode {
                case 49:
                    if !event.isARepeat { viewModel.togglePlayback() }
                    return nil
                case 123:
                    event.isARepeat ? viewModel.arrowHeld(forward: false) : viewModel.stepBackward()
                    return nil
                case 124:
                    event.isARepeat ? viewModel.arrowHeld(forward: true) : viewModel.stepForward()
                    return nil
                default:
                    break
                }
                guard !event.isARepeat else { return event }
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "j": viewModel.pressJ(); return nil
                case "k": viewModel.pressK(); return nil
                case "l": viewModel.pressL(); return nil
                default: return event
                }
            case .keyUp:
                guard unmodified else { return event }
                switch event.keyCode {
                case 123, 124:
                    viewModel.arrowKeyUp()
                    return nil
                default:
                    return event
                }
            default:
                return event
            }
        }

        private func isEditingText(in window: NSWindow?) -> Bool {
            guard let textView = window?.firstResponder as? NSTextView else { return false }
            return textView.isEditable
        }
    }
}
