import Combine
import SwiftUI

@MainActor
final class SecurityScopedResourceAccess {
    private let startAccess: () -> Bool
    private let stopAccess: () -> Void
    private(set) var isAccessing = false

    init(
        url: URL,
        startAccess: (() -> Bool)? = nil,
        stopAccess: (() -> Void)? = nil
    ) {
        self.startAccess = startAccess ?? { url.startAccessingSecurityScopedResource() }
        self.stopAccess = stopAccess ?? { url.stopAccessingSecurityScopedResource() }
    }

    func begin() {
        guard !isAccessing else { return }
        isAccessing = startAccess()
    }

    func end() {
        guard isAccessing else { return }
        stopAccess()
        isAccessing = false
    }
}

@MainActor
final class StandaloneClipCommandContext: ObservableObject {
    @Published private(set) var isCreatingProject = false
    @Published var creationError: String?
    private weak var viewModel: VideoPlayerViewModel?
    private var createAction: (() -> Void)?
    private var closeAction: (() -> Void)?
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

    func configureCloseAction(_ action: @escaping () -> Void) {
        closeAction = action
    }

    func createProject() {
        guard canCreateProject else { return }
        isCreatingProject = true
        createAction?()
    }

    func close() {
        guard NSApp.modalWindow == nil else { return }
        closeAction?()
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
    let request: ExternalMediaOpenRequest
    @Environment(\.newDocument) private var newDocument
    @Environment(\.dismissWindow) private var dismissWindow
    @StateObject private var viewModel: VideoPlayerViewModel
    @StateObject private var commandContext: StandaloneClipCommandContext
    @State private var loadedRequestID: UUID?
    @State private var resourceAccess: SecurityScopedResourceAccess?
    @State private var creationTask: Task<Void, Never>?
    @State private var pendingProject: TrimatoProject?

    init(request: ExternalMediaOpenRequest) {
        self.request = request
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
        .operationProgress(
            mediaPreparationOperation,
            outcome: viewModel.mediaPreparationOutcome
        )
        .operationProgress(commandContext.isCreatingProject ? OperationProgress(
            title: "Creating Project", cancel: { creationTask?.cancel() }
        ) : nil, outcome: commandContext.creationError == nil ? .completed : .failed,
                           completionPending: pendingProject != nil,
                           dismissed: finishProjectPresentation)
        .onDisappear {
            creationTask?.cancel()
            resourceAccess?.end()
        }
        .focusedObject(viewModel)
        .focusedObject(commandContext)
        .onExitCommand {
            commandContext.close()
        }
        .navigationTitle("\((request.displayName as NSString).deletingPathExtension) — \(editorName)")
        .frame(minWidth: 700, minHeight: 600)
        .onAppear {
            commandContext.configureCloseAction {
                dismissWindow(value: request)
            }
            guard loadedRequestID != request.id else {
                resourceAccess?.begin()
                return
            }
            loadedRequestID = request.id
            do {
                let url = try request.resolvedURL()
                let access = SecurityScopedResourceAccess(url: url)
                access.begin()
                resourceAccess = access
                viewModel.load(url: url)
            } catch {
                viewModel.reportMediaOpenFailure(error)
            }
            commandContext.configureCreateAction(createProject)
            viewModel.configureCreateProjectFromClipAction {
                commandContext.createProject()
            }
        }
        .applicationMessage(viewModel.mediaOpenErrorMessage.map {
            ApplicationMessageDescriptor(title: "Clip Could Not Be Opened", message: $0)
        }) {
            viewModel.dismissMediaOpenError()
        }
        .applicationMessage(commandContext.creationError.map {
            ApplicationMessageDescriptor(title: "Project Could Not Be Created", message: $0)
        }) {
            commandContext.creationError = nil
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
        SingleProjectCoordinator.prepareForReplacement { allowed in
            guard allowed else { return }
            newDocument { ProjectDocument(project: project, isExplicitlySaved: false) }
            dismissWindow(value: request)
        }
    }

    private var editorName: String {
        guard viewModel.hasMedia else { return "Clip Editor" }
        return ClipEditorMediaKind.name(hasVideo: viewModel.hasVideo)
    }

    private var mediaPreparationOperation: OperationProgress? {
        guard viewModel.isPreparingMedia else { return nil }
        let detail = viewModel.mediaStatus.map { status in
            viewModel.mediaFilename.isEmpty ? status : "\(viewModel.mediaFilename): \(status)"
        }
        return OperationProgress(
            title: "Preparing Clip",
            progress: viewModel.mediaProgress,
            detail: detail,
            cancel: viewModel.cancelMediaLoad
        )
    }
}
