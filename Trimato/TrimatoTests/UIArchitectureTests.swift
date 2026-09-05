import Foundation
import Testing

struct UIArchitectureTests {
    private var sourceDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Trimato")
    }

    private var swiftSources: [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ))?.filter { $0.pathExtension == "swift" } ?? []
    }

    @Test func appSourceContainsNoAlertAPIs() throws {
        for url in swiftSources {
            let source = try String(contentsOf: url, encoding: .utf8)
            #expect(!source.contains("NSAlert"), "NSAlert found in \(url.lastPathComponent)")
            #expect(!source.contains(".alert("), "SwiftUI Alert found in \(url.lastPathComponent)")
        }
    }

    @Test func appKitRepresentablesStayWithinTheReviewedAllowlist() throws {
        let allowed = Set([
            "ContentView.swift",
            "EditorAccessibilityFocusScope.swift",
            "NativeModalFormController.swift",
            "ProjectCreationWorkflow.swift",
            "ProjectLauncherView.swift",
            "ProjectSourceOutlineView.swift",
            "ProjectWindowSaveCoordinator.swift",
            "TimelineContextMenuKeyBridge.swift",
            "VideoPlayerView.swift",
        ])

        let representableFiles = try swiftSources.filter { url in
            try String(contentsOf: url, encoding: .utf8).contains("NSViewRepresentable")
        }
        #expect(Set(representableFiles.map(\.lastPathComponent)).isSubset(of: allowed))
    }

    @Test func onlyProjectCreationUsesAnAppKitPanel() throws {
        let panelFiles = try swiftSources.filter { url in
            try String(contentsOf: url, encoding: .utf8).contains("NSPanel")
        }
        #expect(Set(panelFiles.map(\.lastPathComponent)) == ["ProjectCreationWorkflow.swift"])
    }
}
