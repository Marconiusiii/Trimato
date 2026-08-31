import Combine
import SwiftUI

@MainActor
final class StandaloneClipCommandContext: ObservableObject {
    @Published private(set) var isCreatingProject = false
    @Published var creationError: String?
    private weak var viewModel: VideoPlayerViewModel?
    private var createAction: (() -> Void)?
    private var viewModelSubscription: AnyCancellable?

    init(viewModel: VideoPlayerViewModel) {
        self.viewModel = viewModel
        viewModelSubscription = viewModel.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var canCreateProject: Bool {
        !isCreatingProject && viewModel?.canCreateProjectFromClip == true
    }

    func configureCreateAction(_ action: @escaping () -> Void) {
        createAction = action
    }

    func createProject() {
        guard canCreateProject else { return }
        isCreatingProject = true
        createAction?()
    }

    func finishCreatingProject() {
        isCreatingProject = false
    }

    func failCreatingProject(_ error: Error) {
        isCreatingProject = false
        creationError = error.localizedDescription
    }
}

struct StandaloneClipEditorView: View {
    let url: URL
    @Environment(\.newDocument) private var newDocument
    @Environment(\.dismissWindow) private var dismissWindow
    @StateObject private var viewModel: VideoPlayerViewModel
    @StateObject private var commandContext: StandaloneClipCommandContext
    @State private var loadedURL: URL?
    @State private var creationTask: Task<Void, Never>?
    @State private var pendingProject: TrimatoProject?

    init(url: URL) {
        self.url = url
        let viewModel = VideoPlayerViewModel()
        _viewModel = StateObject(wrappedValue: viewModel)
        _commandContext = StateObject(wrappedValue: StandaloneClipCommandContext(viewModel: viewModel))
    }

    var body: some View {
        VStack(spacing: 0) {
            ContentView(
                viewModel: viewModel,
                allowsFileOpening: false,
                editorHeading: editorName
            )

            Divider()

            ClipExportControlsView(viewModel: viewModel)
                .padding(.horizontal, 20)
                .padding(.top, 12)

            HStack {
                Button("Create Project from Clip") {
                    commandContext.createProject()
                }
                .buttonStyle(.bordered)
                .disabled(!commandContext.canCreateProject)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(EditorTheme.controlSurface)
        }
        .operationProgress(commandContext.isCreatingProject ? OperationProgress(
            title: "Creating Project", cancel: { creationTask?.cancel() }
        ) : nil, outcome: commandContext.creationError == nil ? .completed : .failed,
                           completionPending: pendingProject != nil,
                           dismissed: finishProjectPresentation)
        .onDisappear { creationTask?.cancel() }
        .focusedObject(viewModel)
        .focusedObject(commandContext)
        .navigationTitle("\(url.deletingPathExtension().lastPathComponent) — \(editorName)")
        .frame(minWidth: 700, minHeight: 600)
        .onAppear {
            guard loadedURL != url else { return }
            loadedURL = url
            viewModel.load(url: url)
            commandContext.configureCreateAction(createProject)
            viewModel.configureCreateProjectFromClipAction {
                commandContext.createProject()
            }
        }
        .alert("Project Could Not Be Created", isPresented: Binding(
            get: { commandContext.creationError != nil },
            set: { if !$0 { commandContext.creationError = nil } }
        )) {
            Button("OK") { commandContext.creationError = nil }
        } message: {
            Text(commandContext.creationError ?? "The project could not be created from this clip.")
        }
    }

    private func createProject() {
        creationTask = Task { @MainActor in
            do {
                let project = try await viewModel.makeProjectFromCurrentClip()
                try Task.checkCancellation()
                pendingProject = project
                commandContext.finishCreatingProject()
            } catch is CancellationError {
                commandContext.finishCreatingProject()
            } catch {
                commandContext.failCreatingProject(error)
            }
        }
    }

    private func finishProjectPresentation() {
        guard !commandContext.isCreatingProject, let project = pendingProject else { return }
        pendingProject = nil
        newDocument { ProjectDocument(project: project, isExplicitlySaved: false) }
        dismissWindow(value: url)
    }

    private var editorName: String {
        guard viewModel.hasMedia else { return "Clip Editor" }
        return ClipEditorMediaKind.name(hasVideo: viewModel.hasVideo)
    }
}
