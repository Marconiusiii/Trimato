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

    @Test func blockingWorkflowsAreNotModelessSwiftUIScenes() throws {
        let appSource = try String(
            contentsOf: sourceDirectory.appendingPathComponent("TrimatoApp.swift"),
            encoding: .utf8
        )
        let forbiddenScenes = [
            "WindowGroup(\"Generator\"",
            "WindowGroup(\"Finalize Captions\"",
            "WindowGroup(\"Caption Editor\"",
            "WindowGroup(\"Progress\"",
            "WindowGroup(\"Message\"",
        ]

        for scene in forbiddenScenes {
            #expect(!appSource.contains(scene), "Blocking workflow remains a modeless scene: \(scene)")
        }

        let modalSource = try String(
            contentsOf: sourceDirectory.appendingPathComponent("NativeModalFormController.swift"),
            encoding: .utf8
        )
        #expect(!modalSource.contains("NSApp.runModal(for: window)"))
        #expect(modalSource.contains("NSApp.beginModalSession(for: window)"))
        #expect(modalSource.contains("NSApp.runModalSession(modalSession)"))
        #expect(modalSource.contains("NSApp.endModalSession(modalSession)"))
    }

    @Test func projectSourceFocusDoesNotIndexAccessibilityRowsOrRunInline() throws {
        let source = try String(
            contentsOf: sourceDirectory.appendingPathComponent("ProjectSourceOutlineView.swift"),
            encoding: .utf8
        )
        #expect(!source.contains("accessibilityRows()"))
        #expect(source.contains("accessibilitySelectedRows()?.first"))
        #expect(source.contains("Task { @MainActor [weak self] in"))
    }

    @Test func generatorHasOneEditorScopedKeyboardRoute() throws {
        let appSource = try String(
            contentsOf: sourceDirectory.appendingPathComponent("TrimatoApp.swift"),
            encoding: .utf8
        )
        let playerSource = try String(
            contentsOf: sourceDirectory.appendingPathComponent("ProjectPlayerViewModel.swift"),
            encoding: .utf8
        )
        #expect(!appSource.contains(".keyboardShortcut(\"g\", modifiers: [])"))
        #expect(!playerSource.contains("projectKeyboardCommandsAreActive"))
        #expect(playerSource.contains("case \"g\":"))
        #expect(playerSource.contains("self.openGenerator?()"))
    }

    @Test func nativeModalFocusStartsAfterTheWindowBecomesKey() throws {
        let modalSource = try String(
            contentsOf: sourceDirectory.appendingPathComponent("NativeModalFormController.swift"),
            encoding: .utf8
        )
        #expect(modalSource.contains("func windowDidBecomeKey"))
        #expect(modalSource.contains("focusRequest?.request()"))

        for filename in [
            "ApplicationMessageView.swift",
            "CaptionEditorWindowController.swift",
            "CaptionFinalizationResultsView.swift",
            "GeneratorView.swift",
            "OperationProgressWindow.swift",
        ] {
            let source = try String(
                contentsOf: sourceDirectory.appendingPathComponent(filename),
                encoding: .utf8
            )
            #expect(source.contains("focusRequest.revision"), "Missing keyed focus lifecycle in \(filename)")
        }
    }
}
