import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ProjectLauncherView: View {
    @Environment(\.newDocument) private var newDocument
    @Environment(\.openDocument) private var openDocument

    @ObservedObject private var navigation = ProjectLauncherNavigation.shared
    @StateObject private var recentProjects = RecentProjectStore()
    @State private var presentedError: ProjectLauncherError?
    @State private var launcherWindow: NSWindow?
    @AccessibilityFocusState private var newProjectFocused: Bool

    var body: some View {
        Group {
            if navigation.isCreatingProject {
                newProjectOptions
            } else {
                launcherContent
            }
        }
        .padding(32)
        .frame(width: 560, height: 680)
        .background(EditorTheme.workspace)
        .tint(EditorTheme.accent)
        .preferredColorScheme(.dark)
        .background(ProjectLauncherWindowBridge { launcherWindow = $0 })
        .onAppear {
            recentProjects.refresh()
            if !navigation.isCreatingProject { newProjectFocused = true }
        }
        .onDisappear { navigation.showWelcome() }
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

    private var newProjectOptions: some View {
        ProjectCreationView(
            initialProject: TrimatoProject(),
            heading: "New Project",
            actionTitle: "Create Project",
            finish: createProject,
            cancel: cancelProjectCreation
        )
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
        HStack(spacing: 12) {
            Button("New Project") {
                beginProjectCreation()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityFocused($newProjectFocused)

            Button("Open Project…") {
                chooseProject()
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
    }

    private func beginProjectCreation() {
        newProjectFocused = false
        navigation.showProjectCreation()
    }

    private func cancelProjectCreation() {
        navigation.showWelcome()
        DispatchQueue.main.async { newProjectFocused = true }
    }

    private func createProject(with values: ProjectSettingsValues) {
        let project = values.applying(to: TrimatoProject())
        navigation.showWelcome()
        newDocument {
            ProjectDocument(project: project, isExplicitlySaved: false)
        }
        closeLauncher()
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
        launcherWindow?.performClose(nil)
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

private struct ProjectLauncherWindowBridge: NSViewRepresentable {
    let windowChanged: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ProjectLauncherWindowView {
        let view = ProjectLauncherWindowView(frame: .zero)
        view.windowChanged = windowChanged
        return view
    }

    func updateNSView(_ nsView: ProjectLauncherWindowView, context: Context) {
        nsView.windowChanged = windowChanged
        windowChanged(nsView.window)
    }
}

private final class ProjectLauncherWindowView: NSView {
    var windowChanged: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowChanged?(window)
    }
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
