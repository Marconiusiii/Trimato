import AppKit
import SwiftUI
import Testing
@testable import Trimato

@MainActor
@Suite(.serialized)
struct GeneratorHandoffTests {
    private var preparationWindows: [NSWindow] {
        NSApp.windows.filter { $0.isVisible && $0.identifier?.rawValue == "Trimato.OperationProgress" }
    }

    @Test(arguments: [GeneratorKind.black, .text], [false, true])
    func nativePreparationWindowClosesBeforeCompletion(kind: GeneratorKind, cached: Bool) async throws {
        let controller = ProjectController(document: ProjectDocument(project: TrimatoProject()))
        let session = GeneratorSession(controller: controller)
        session.definition.kind = kind
        session.definition.width = 160
        session.definition.height = 120
        session.definition.duration = ProjectTime(seconds: 1)
        session.durationValue = 1
        if kind == .text { session.definition.textSettings.text = "Handoff \(UUID())" }
        if cached { _ = try await GeneratorRenderer.ensure(session.definition) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 800),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        session.hostWindow = window
        var completionCount = 0
        let host = NSHostingView(rootView: GeneratorView(session: session, focusRequest: NativeModalFocusRequest(),
            close: {
                #expect(preparationWindows.isEmpty, "Generator completion must wait for its progress window to close")
                completionCount += 1
            }))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { session.cancelPreparation(); window.close() }
        try await Task.sleep(for: .milliseconds(100))
        session.prepare(placement: .insert) {
            #expect(preparationWindows.isEmpty)
            completionCount += 1
        }
        for _ in 0..<500 where completionCount == 0 {
            #expect(window.attachedSheet == nil, "Generator must retain its established progress-window presentation")
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(completionCount == 1)
        #expect(preparationWindows.isEmpty)
        #expect(window.attachedSheet == nil)
        #expect(session.progress == nil && !session.hasPendingCompletion)
        #expect(session.errorMessage == nil)
        #expect(controller.project.media.first?.generator?.kind == kind)
        try await Task.sleep(for: .milliseconds(100))
        #expect(completionCount == 1)
    }

    @Test func immediateCompletionWithoutAnObservedProgressStateRunsOnce() async throws {
        var completions = 0
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Text("Generator")
            .operationProgress(nil, completionRequested: true, dismissed: { completions += 1 }))
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(completions == 1 && preparationWindows.isEmpty)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(completions == 1)
    }

    @Test func cancellationAndInvalidInputDoNotCommitACompletion() async throws {
        let controller = ProjectController(document: ProjectDocument(project: TrimatoProject()))
        let session = GeneratorSession(controller: controller)
        session.definition.width = 160
        session.definition.height = 120
        session.durationValue = 1
        var completions = 0
        session.prepare(placement: .insert) { completions += 1 }
        session.cancelPreparation()
        try await Task.sleep(for: .milliseconds(150))
        #expect(controller.project.media.isEmpty && completions == 0)
        #expect(session.progress == nil && !session.hasPendingCompletion)
        session.durationValue = 0
        session.prepare(placement: .insert) { completions += 1 }
        #expect(session.errorMessage != nil && completions == 0 && controller.project.media.isEmpty)
    }
}
