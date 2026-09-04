import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ProjectLauncherView: View {
    @Environment(\.openDocument) private var openDocument
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @ObservedObject private var navigation = ProjectLauncherNavigation.shared
    @StateObject private var recentProjects = RecentProjectStore()
    @State private var presentedError: ProjectLauncherError?

    var body: some View {
        launcherContent
        .padding(32)
        .frame(width: 560, height: 680)
        .background(EditorTheme.workspace)
        .tint(EditorTheme.accent)
        .preferredColorScheme(.dark)
        .background(ProjectCreationSheetPresenter(
            isPresented: navigation.isCreatingProject,
            projectCreated: openCreatedProject,
            presentationEnded: cancelProjectCreation
        ))
        .onAppear { recentProjects.refresh() }
        .onDisappear {
            navigation.showWelcome()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            recentProjects.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            recentProjects.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .trimatoProjectDidOpen)) { _ in
            closeLauncher()
        }
        .alert(item: $presentedError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var launcherContent: some View {
        VStack(spacing: 24) {
            welcome
            primaryActions
            recentProjectGroup
        }
    }

    private var welcome: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(EditorTheme.raisedSurface)
                    .frame(width: 124, height: 124)
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 104, height: 104)
            }
            .accessibilityHidden(true)

            Text("Welcome to Trimato")
                .font(.largeTitle.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            Text("Create a project or continue editing.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var primaryActions: some View {
        ProjectLauncherNativeActions(
            newProject: beginProjectCreation,
            trimClip: chooseClip,
            openProject: chooseProject
        )
        .frame(height: 34)
    }

    private func beginProjectCreation() {
        navigation.showProjectCreation()
    }

    private func cancelProjectCreation() {
        navigation.showWelcome()
    }

    private func openCreatedProject(at url: URL) {
        openProject(at: url)
    }

    private var recentProjectGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Projects")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if recentProjects.urls.isEmpty {
                        Text("No recent projects")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(recentProjects.urls, id: \.self) { url in
                            Button(ProjectLauncherRecentProjects.displayName(for: url)) {
                                openProject(at: url)
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(url.deletingLastPathComponent().path)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = "Open Trimato Project"
        panel.prompt = "Open"
        panel.allowedContentTypes = [.trimatoProject]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url)
    }

    private func chooseClip() {
        let panel = NSOpenPanel()
        panel.title = "Trim a Clip"
        panel.prompt = "Open"
        panel.allowedContentTypes = [.movie, .audio, .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openWindow(value: url)
    }

    private func openProject(at url: URL) {
        Task { @MainActor in
            do {
                try await openDocument(at: url)
                recentProjects.refresh()
                closeLauncher()
            } catch {
                recentProjects.refresh()
                presentedError = ProjectLauncherError(
                    title: "Project Could Not Be Opened",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func closeLauncher() {
        dismissWindow(id: "project-launcher")
    }
}

private struct ProjectLauncherNativeActions: NSViewRepresentable {
    let newProject: () -> Void
    let trimClip: () -> Void
    let openProject: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ActionStack {
        let stack = ActionStack()
        stack.owner = context.coordinator
        context.coordinator.stack = stack
        context.coordinator.configureActions(
            newProject: newProject,
            trimClip: trimClip,
            openProject: openProject
        )
        return stack
    }

    func updateNSView(_ stack: ActionStack, context: Context) {
        context.coordinator.configureActions(
            newProject: newProject,
            trimClip: trimClip,
            openProject: openProject
        )
        context.coordinator.configureDefaultButton()
    }

    static func dismantleNSView(_ stack: ActionStack, coordinator: Coordinator) {
        coordinator.stopObservingWindow()
    }

    final class Coordinator: NSObject {
        weak var stack: ActionStack?
        private var newProject: (() -> Void)?
        private var trimClip: (() -> Void)?
        private var openProject: (() -> Void)?
        private var windowObserver: NSObjectProtocol?

        func configureActions(
            newProject: @escaping () -> Void,
            trimClip: @escaping () -> Void,
            openProject: @escaping () -> Void
        ) {
            self.newProject = newProject
            self.trimClip = trimClip
            self.openProject = openProject
        }

        func configureDefaultButton() {
            guard let stack, let window = stack.window else { return }
            ProjectCreationWindowConfiguration.configureDefaultButton(stack.newProjectButton, in: window)
        }

        func observeWindow() {
            stopObservingWindow()
            guard let window = stack?.window else { return }
            windowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.configureDefaultButton() }
            }
            Task { @MainActor [weak self] in self?.configureDefaultButton() }
        }

        func stopObservingWindow() {
            if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
            windowObserver = nil
        }

        @objc func newProjectPressed() { newProject?() }
        @objc func trimClipPressed() { trimClip?() }
        @objc func openProjectPressed() { openProject?() }
    }

    final class ActionStack: NSStackView {
        weak var owner: Coordinator?
        let newProjectButton = NSButton(title: "New Project", target: nil, action: nil)

        init() {
            super.init(frame: .zero)
            orientation = .horizontal
            spacing = 12
            alignment = .centerY
            distribution = .fillProportionally

            let trimClipButton = NSButton(title: "Trim a Clip", target: nil, action: nil)
            let openProjectButton = NSButton(title: "Open Project…", target: nil, action: nil)
            for button in [newProjectButton, trimClipButton, openProjectButton] {
                button.bezelStyle = .rounded
                button.controlSize = .large
                addArrangedSubview(button)
            }
            newProjectButton.keyEquivalent = "\r"
            newProjectButton.keyEquivalentModifierMask = []
            newProjectButton.identifier = NSUserInterfaceItemIdentifier("trimato.launcher.new-project")
            trimClipButton.identifier = NSUserInterfaceItemIdentifier("trimato.launcher.trim-clip")
            openProjectButton.identifier = NSUserInterfaceItemIdentifier("trimato.launcher.open-project")
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let owner else { return }
            newProjectButton.target = owner
            newProjectButton.action = #selector(Coordinator.newProjectPressed)
            (arrangedSubviews[1] as? NSButton)?.target = owner
            (arrangedSubviews[1] as? NSButton)?.action = #selector(Coordinator.trimClipPressed)
            (arrangedSubviews[2] as? NSButton)?.target = owner
            (arrangedSubviews[2] as? NSButton)?.action = #selector(Coordinator.openProjectPressed)
            owner.observeWindow()
        }
    }
}

@MainActor
final class ProjectLauncherNavigation: ObservableObject {
    static let shared = ProjectLauncherNavigation()

    @Published private(set) var isCreatingProject = false

    func showProjectCreation() {
        isCreatingProject = true
    }

    func showWelcome() {
        isCreatingProject = false
    }
}

extension Notification.Name {
    static let trimatoProjectDidOpen = Notification.Name("TrimatoProjectDidOpen")
}

@MainActor
final class RecentProjectStore: ObservableObject {
    @Published private(set) var urls: [URL] = []

    func refresh() {
        urls = ProjectLauncherRecentProjects.available(
            from: NSDocumentController.shared.recentDocumentURLs
        )
    }
}

nonisolated enum ProjectLauncherRecentProjects {
    static let maximumCount = 8

    static func available(
        from urls: [URL],
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> [URL] {
        var seen: Set<URL> = []
        var result: [URL] = []
        for url in urls {
            guard url.pathExtension.caseInsensitiveCompare("trimato") == .orderedSame,
                  fileExists(url.path),
                  seen.insert(url.standardizedFileURL).inserted else { continue }
            result.append(url)
            if result.count == maximumCount { break }
        }
        return result
    }

    static func displayName(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}

private struct ProjectLauncherError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
