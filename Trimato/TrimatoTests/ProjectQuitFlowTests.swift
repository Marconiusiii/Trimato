import AppKit
import SwiftUI
import Testing
@testable import Trimato

@Suite("Coordinated project quitting", .serialized)
@MainActor
struct ProjectQuitFlowTests {
    @Test func validatesAllDraftsBeforeApplyingAny() async {
        let edits = ProjectQuitEdits()
        var applied = 0
        edits.register(UUID(), entry: .init(priority: 0, hasChanges: { true }, validate: {}, apply: { applied += 1 }))
        edits.register(UUID(), entry: .init(priority: 100, hasChanges: { true }, validate: {
            throw QuitDraftError(message: "Invalid range")
        }, apply: { applied += 1 }))
        do { try await edits.apply(); Issue.record("Invalid draft was accepted") } catch { }
        #expect(applied == 0)
    }

    @Test func childFilterIsAppliedBeforeParentEvenWhenParentInitiallyClean() async throws {
        let edits = ProjectQuitEdits()
        var childChanged = false
        var saved = 0
        var filterApplications = 0
        edits.register(UUID(), entry: .init(priority: 100, hasChanges: { childChanged }, validate: {}, apply: {
            saved += 1
            childChanged = false
        }))
        edits.register(UUID(), entry: .init(priority: 0, hasChanges: { true }, validate: {}, apply: {
            filterApplications += 1
            childChanged = true
        }))
        try await edits.apply()
        #expect(saved == 1)
        #expect(filterApplications == 1)
        try await edits.apply()
        #expect(saved == 1)
        #expect(filterApplications == 1)
    }

    @Test func discardClosesEditorAfterSheetDetachesWithoutAnotherKeyEvent() async throws {
        let context = makeContext()
        context.audioSettings?.lowGainDecibels = 6
        let editor = ClipEditorWindowController(title: "Test editor", rootView: Text("Editor"), commandContext: context)
        editor.showAndFocus()
        let window = try #require(editor.window)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 140), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        defer { window.close(); sheet.close() }
        var result: Bool?
        editor.requestClose { result = $0 }
        try #require(context.closeConfirmationRequested)
        window.beginSheet(sheet, completionHandler: { _ in })
        context.chooseCloseDecision(.discard)
        context.completeCloseConfirmation()
        await Task.yield()
        #expect(window.isVisible)
        #expect(result == nil)
        window.endSheet(sheet)
        for _ in 0..<100 where result == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(result == true)
        #expect(!window.isVisible)
    }

    @Test func dismissalCancelsExactlyOnceAndAllowsAnotherClose() async throws {
        let context = makeContext()
        context.audioSettings?.lowGainDecibels = 3
        let editor = ClipEditorWindowController(title: "Test editor", rootView: Text("Editor"), commandContext: context)
        editor.showAndFocus()
        defer { editor.window?.close() }
        var outcomes: [Bool] = []
        editor.requestClose { outcomes.append($0) }
        context.completeCloseConfirmation()
        context.completeCloseConfirmation()
        for _ in 0..<100 where outcomes.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(outcomes == [false])
        editor.requestClose { outcomes.append($0) }
        context.chooseCloseDecision(.discard)
        context.completeCloseConfirmation()
        for _ in 0..<100 where outcomes.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(outcomes == [false, true])
    }

    @Test func saveAndQuitIncludesDraftsAndCompletesOnlyOnce() async throws {
        let (model, native, coordinator, window) = makeDocument()
        defer { native.close(); window.close(); QuitReviewState.shared.coordinator = nil }
        let edits = ProjectQuitEdits()
        var applications = 0
        edits.register(UUID(), entry: .init(priority: 0, hasChanges: { true }, validate: {}, apply: {
            applications += 1
            model.project.name = "Applied draft"
        }))
        var outcomes: [Bool] = []
        coordinator.requestQuit(edits: edits) { outcomes.append($0) }
        #expect(coordinator.isConfirmingClose)
        coordinator.chooseCloseDecision(.save)
        coordinator.closeConfirmationDismissed()
        coordinator.closeConfirmationDismissed()
        for _ in 0..<100 where outcomes.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(outcomes == [true])
        #expect(applications == 1)
        #expect(native.saves == 1)
        #expect(model.project.name == "Applied draft")
        #expect(!model.hasUnsavedChanges)
    }

    @Test func cancelThenDiscardDoesNotApplyPendingDrafts() async throws {
        let (model, native, coordinator, window) = makeDocument()
        defer { native.close(); window.close(); QuitReviewState.shared.coordinator = nil }
        let edits = ProjectQuitEdits()
        var applied = false
        edits.register(UUID(), entry: .init(priority: 0, hasChanges: { true }, validate: {}, apply: { applied = true }))
        var outcomes: [Bool] = []
        coordinator.requestQuit(edits: edits) { outcomes.append($0) }
        coordinator.cancelQuitReview()
        #expect(outcomes == [false])
        #expect(edits.hasChanges)
        #expect(!coordinator.isApplicationTerminating)
        model.project.name = "Unsaved project change"
        coordinator.requestQuit(edits: edits) { outcomes.append($0) }
        coordinator.chooseCloseDecision(.discard)
        coordinator.closeConfirmationDismissed()
        #expect(outcomes == [false, true])
        #expect(!applied)
        #expect(model.project.name == "Saved baseline")
    }

    @Test func failedSaveKeepsProjectAndRetryDoesNotDuplicateDraft() async throws {
        let (model, native, coordinator, window) = makeDocument()
        defer { native.close(); window.close(); QuitReviewState.shared.coordinator = nil }
        native.failSave = true
        let edits = ProjectQuitEdits()
        var applications = 0
        edits.register(UUID(), entry: .init(priority: 0, hasChanges: { true }, validate: {}, apply: {
            applications += 1
            model.project.name = "Draft preserved"
        }))
        var outcomes: [Bool] = []
        coordinator.requestQuit(edits: edits) { outcomes.append($0) }
        coordinator.chooseCloseDecision(.save)
        coordinator.closeConfirmationDismissed()
        for _ in 0..<100 where outcomes.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(outcomes == [false])
        #expect(model.hasUnsavedChanges)
        #expect(model.project.name == "Draft preserved")
        native.failSave = false
        coordinator.requestQuit(edits: edits) { outcomes.append($0) }
        coordinator.chooseCloseDecision(.save)
        coordinator.closeConfirmationDismissed()
        for _ in 0..<100 where outcomes.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(outcomes == [false, true])
        #expect(applications == 1)
    }

    @Test func openFilterAndEQReachProjectWithoutWaitingForPreview() async throws {
        let context = makeContext()
        let routes = ExternalMediaOpenCoordinator.shared
        routes.register(controller: context.controller, openClipEditor: { _ in })
        routes.activate(controller: context.controller)
        defer { routes.unregister(controller: context.controller) }
        context.audioSettings?.lowGainDecibels = 5
        context.effectsReady = false
        let view = AddClipFilterView(audio: true, existing: [], voiceContext: context, add: { _ in }, cancel: {})
        let editor = ClipEditorWindowController(title: "Draft filter", rootView: view, commandContext: context)
        editor.showAndFocus()
        defer { editor.window?.close() }
        try await Task.sleep(for: .milliseconds(200))
        try await context.controller.quitEdits.apply()
        guard case .timelineClip(let id) = context.editSelection else { Issue.record("Missing clip"); return }
        let clip = try #require(context.controller.project.timelineClip(id: id))
        #expect(clip.audioSettings.lowGainDecibels == 5)
        #expect(clip.filters.count == 1)
        #expect(!context.hasUncommittedChanges)
        try await context.controller.quitEdits.apply()
        #expect(context.controller.project.timelineClip(id: id)?.filters.count == 1)
    }

    @Test func invalidDraftKeepsQuitReviewAvailableAndCanBeCancelled() async throws {
        let (_, native, coordinator, window) = makeDocument()
        defer { native.close(); window.close(); QuitReviewState.shared.coordinator = nil }
        let edits = ProjectQuitEdits()
        edits.register(UUID(), entry: .init(priority: 0, hasChanges: { true }, validate: {
            throw QuitDraftError(message: "Correct the clip range.")
        }, apply: { Issue.record("Invalid draft applied") }))
        var result: Bool?
        coordinator.requestQuit(edits: edits) { result = $0 }
        coordinator.chooseCloseDecision(.save)
        coordinator.closeConfirmationDismissed()
        for _ in 0..<100 where coordinator.quitError == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(coordinator.quitError == "Correct the clip range.")
        #expect(coordinator.isConfirmingClose)
        #expect(!coordinator.isResolvingClose)
        #expect(result == nil)
        coordinator.cancelQuitReview()
        #expect(result == false)
        #expect(edits.hasChanges)
    }

    @Test func closingNativeQuitReviewCancelsOriginalRequest() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = try ProjectDocument.writeNewProject(TrimatoProject(name: "Quit review"), toFolderAt: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        await withCheckedContinuation { continuation in
            SingleProjectCoordinator.shared.openDocument(at: url) { continuation.resume() }
        }
        let native = try #require(NSDocumentController.shared.document(for: url))
        defer { native.close(); QuitReviewState.shared.coordinator = nil }
        let controller = try #require(ExternalMediaOpenCoordinator.shared.activeProjectController)
        for _ in 0..<100 where controller.projectSaveCoordinator == nil { try await Task.sleep(for: .milliseconds(10)) }
        let coordinator = try #require(controller.projectSaveCoordinator)
        for _ in 0..<100 where coordinator.attachedWindow == nil { try await Task.sleep(for: .milliseconds(10)) }
        try #require(coordinator.attachedWindow != nil)
        controller.quitEdits.register(UUID(), entry: .init(priority: 0, hasChanges: { true }, validate: {}, apply: {}))
        var result: Bool?
        controller.closeProjectForQuit { result = $0 }
        var review: NSWindow?
        for _ in 0..<100 {
            review = NSApp.windows.first { $0.title == "Save changes before quitting?" && $0.isVisible }
            if review != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let presented = try #require(review, "Confirmation: \(coordinator.isConfirmingClose), result: \(String(describing: result)), windows: \(NSApp.windows.map { "\($0.title):\($0.isVisible)" })")
        #expect(presented !== coordinator.attachedWindow)
        presented.performClose(nil)
        for _ in 0..<100 where result == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(result == false)
        #expect(!coordinator.isApplicationTerminating)
        #expect(NSDocumentController.shared.document(for: url) != nil)
    }

    @Test func cancellingQuitResumesExistingModalEditorWithoutClosingIt() async throws {
        let (_, native, coordinator, window) = makeDocument()
        defer { native.close(); window.close(); QuitReviewState.shared.coordinator = nil }
        var editorClosed = false
        let modal = NativeModalWindowController(title: "Pending caption", contentSize: NSSize(width: 350, height: 180),
            rootView: Text("Caption draft"), returnWindow: window, closed: { editorClosed = true })
        modal.showModal()
        try await Task.sleep(for: .milliseconds(70))
        #expect(NSApp.modalWindow === modal.window)
        let edits = ProjectQuitEdits()
        edits.register(UUID(), entry: .init(priority: 0, hasChanges: { true }, validate: {}, apply: {}))
        var result: Bool?
        coordinator.requestQuit(edits: edits) { result = $0 }
        #expect(NSApp.modalWindow == nil)
        #expect(!editorClosed)
        coordinator.cancelQuitReview()
        try await Task.sleep(for: .milliseconds(70))
        #expect(result == false)
        #expect(NSApp.modalWindow === modal.window)
        #expect(!editorClosed)
        modal.closeModal()
        for _ in 0..<100 where !editorClosed { try await Task.sleep(for: .milliseconds(10)) }
        #expect(editorClosed)
    }

    @Test func sourceOnlyAudioSettingsAreNotSilentlyDiscardedBySaveAndQuit() async throws {
        let timelineContext = makeContext()
        let controller = timelineContext.controller
        let asset = try #require(controller.project.media.first)
        let context = ClipPlacementCommandContext(controller: controller, editSelection: .asset(asset.id), segments: asset.sourceEdit)
        context.audioSettings?.lowGainDecibels = 4
        let editor = ClipEditorWindowController(title: "Source", rootView: Text("Source"), commandContext: context)
        defer { editor.window?.close() }
        #expect(controller.quitEdits.hasChanges)
        do {
            try await controller.quitEdits.apply()
            Issue.record("Unplaced source settings were discarded")
        } catch {
            #expect(error.localizedDescription.contains("Add the source clip to a track"))
        }
        #expect(context.audioSettings?.lowGainDecibels == 4)
    }

    private func makeDocument() -> (ProjectDocument, QuitTestDocument, ProjectWindowSaveCoordinator, NSWindow) {
        let model = ProjectDocument(project: TrimatoProject(name: "Saved baseline"))
        model.markProjectAsExplicitlySaved(model.project)
        let native = QuitTestDocument()
        native.fileURL = URL(fileURLWithPath: "/tmp/quit-flow-test.trimato")
        native.fileType = "com.marconius.trimato.project"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        native.addWindowController(NSWindowController(window: window))
        NSDocumentController.shared.addDocument(native)
        let coordinator = ProjectWindowSaveCoordinator(projectDocument: model)
        coordinator.attach(to: window)
        return (model, native, coordinator, window)
    }

    private func makeContext() -> ClipPlacementCommandContext {
        var project = TrimatoProject()
        let asset = MediaAssetRecord(name: "Voice", originalPath: "/tmp/quit-test.wav", duration: ProjectTime(seconds: 3),
            hasAudio: true, sourceEdit: [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 3)))])
        let id = project.putRecording(asset, at: .zero)
        let controller = ProjectController(document: ProjectDocument(project: project))
        return ClipPlacementCommandContext(controller: controller, editSelection: .timelineClip(id), segments: asset.sourceEdit)
    }
}

@MainActor
private final class QuitTestDocument: NSDocument {
    var saves = 0
    var failSave = false
    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        saves += 1
        completionHandler(failSave ? CocoaError(.fileWriteNoPermission) : nil)
    }
}
