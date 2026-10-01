import AppKit
import SwiftUI
import Testing
@testable import Trimato

@MainActor
@Suite(.serialized)
struct GeneratorHandoffTests {
    @Test(arguments: [GeneratorKind.black, .text], [false, true])
    func nativePreparationDismissesBeforeCompletion(kind: GeneratorKind, cached: Bool) async throws {
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
                #expect(window.attachedSheet == nil, "Generator completion must wait for native sheet detachment")
                completionCount += 1
            }))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { session.cancelPreparation(); window.close() }
        try await Task.sleep(for: .milliseconds(100))
        session.prepare(placement: .insert) {
            #expect(window.attachedSheet == nil)
            completionCount += 1
        }
        for _ in 0..<500 where completionCount == 0 {
            if let sheet = window.attachedSheet {
                #expect(sheet.contentView != nil)
                sheet.contentView?.layoutSubtreeIfNeeded()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(completionCount == 1)
        #expect(window.attachedSheet == nil)
        #expect(session.progress == nil && !session.hasPendingCompletion)
        #expect(session.errorMessage == nil)
        #expect(controller.project.media.first?.generator?.kind == kind)
        try await Task.sleep(for: .milliseconds(100))
        #expect(completionCount == 1)
    }

    @Test func immediateCompletionWithoutAnObservedProgressStateRunsOnce() {
        let presentation = ClipPreparationSheetPresentation(postsAnnouncements: false)
        var completions = 0
        presentation.synchronize(operation: nil, outcome: .completed, completionPending: false,
            completionRequested: true, dismissed: { completions += 1 })
        #expect(completions == 1 && presentation.session == nil && !presentation.isPresented)
        presentation.synchronize(operation: nil, outcome: .completed, completionPending: false,
            dismissed: { completions += 1 })
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
