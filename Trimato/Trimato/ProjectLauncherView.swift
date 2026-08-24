import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ProjectLauncherView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.newDocument) private var newDocument
    @Environment(\.openDocument) private var openDocument

    @StateObject private var recentProjects = RecentProjectStore()
    @State private var presentedError: ProjectLauncherError?
    @AccessibilityFocusState private var newProjectFocused: Bool

    var body: some View {
        VStack(spacing: 24) {
            welcome
            primaryActions
            recentProjectGroup
        }
        .padding(32)
        .frame(width: 560, height: 680)
        .background(EditorTheme.workspace)
        .tint(EditorTheme.accent)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project Launcher")
        .onAppear {
            recentProjects.refresh()
            newProjectFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            recentProjects.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            recentProjects.refresh()
        }
        .alert(item: $presentedError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
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
        HStack(spacing: 12) {
            Button("New Project") {
                newDocument { ProjectDocument() }
                dismiss()
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

    private var recentProjectGroup: some View {
        GroupBox("Recent Projects") {
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
                dismiss()
            } catch {
                recentProjects.refresh()
                presentedError = ProjectLauncherError(
                    title: "Project Could Not Be Opened",
                    message: error.localizedDescription
                )
            }
        }
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
