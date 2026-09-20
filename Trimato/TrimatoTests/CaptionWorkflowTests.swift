import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Trimato

@Suite(.serialized)
@MainActor
struct CaptionWorkflowTests {
    @Test func captionControlsUseNativeOrderAndQualifiedTimecodes() async throws {
        let range = ProjectTimeRange(start: ProjectTime(seconds: 2), duration: ProjectTime(seconds: 3))
        let session = CaptionEditorWindowSession(cue: nil, range: range, save: { _ in }, play: {}, finished: {})
        session.text = "A caption for review."
        let host = NSHostingView(rootView: CaptionEditorView(session: session, focusRequest: NativeModalFocusRequest()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        let elements = accessibilityDescendants(host)
        let values = elements.compactMap { accessibilityAttribute($0, "accessibilityValue") as? String }
        #expect(values.contains("In Time: 00:00:02.000"))
        #expect(values.contains("Out Time: 00:00:05.000"))
        let controls = elements.filter {
            ["AXTextArea", "AXButton", "AXMenuButton", "AXPopUpButton"].contains(
                accessibilityAttribute($0, "accessibilityRole") as? String ?? "")
        }
        let names = controls.map { item in
            let role = accessibilityAttribute(item, "accessibilityRole") as? String
            if role == "AXTextArea" { return "AXTextArea" }
            // SwiftUI's menu title is unavailable through this in-process AX reader.
            // Its native role still verifies its position between text and playback.
            if role == "AXMenuButton" { return "AXMenuButton" }
            return (accessibilityAttribute(item, "accessibilityTitle") as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (accessibilityAttribute(item, "accessibilityLabel") as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (accessibilityAttribute(item, "accessibilityValue") as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? ""
        }
        #expect(names == ["AXTextArea", "AXMenuButton", "Play Selection", "Cancel", "Add Caption", "Help"])
        #expect(host.fittingSize.width <= 441)
    }

    @Test func sharedModalActionsExposeHelpLast() async throws {
        let host = NSHostingView(rootView: NativeModalActions(helpTopic: .filters, primaryTitle: "Apply", cancel: {}, primary: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        let names = accessibilityDescendants(host).filter {
            accessibilityAttribute($0, "accessibilityRole") as? String == "AXButton"
        }.map {
            (accessibilityAttribute($0, "accessibilityTitle") as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? accessibilityAttribute($0, "accessibilityLabel") as? String ?? ""
        }
        #expect(names == ["Cancel", "Apply", "Help"])
    }

    private func accessibilityAttribute(_ item: NSObject, _ key: String) -> Any? {
        item.responds(to: NSSelectorFromString(key)) ? item.value(forKey: key) : nil
    }

    private func accessibilityDescendants(_ item: NSObject) -> [NSObject] {
        [item] + ((accessibilityAttribute(item, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(accessibilityDescendants)
    }

    private func controller() -> ProjectController {
        var project = TrimatoProject()
        project.tracks = [TimelineTrack(
            name: "Primary Video",
            kind: .video,
            role: .primaryVideo,
            clips: [TimelineClip(
                assetID: UUID(),
                name: "Picture",
                segments: [SourceSegment(sourceRange: ProjectTimeRange(
                    start: .zero,
                    duration: ProjectTime(seconds: 20)
                ))]
            )]
        )]
        return ProjectController(document: ProjectDocument(project: project))
    }

    @Test func addingUpdatingDeletingAndUndoingACaptionUsesProjectMutations() throws {
        let controller = controller()
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.installUndoManager(undo)

        undo.beginUndoGrouping()
        let id = try controller.addCaptionCue(
            start: ProjectTime(seconds: 2),
            end: ProjectTime(seconds: 4),
            text: "Original"
        )
        undo.endUndoGrouping()
        #expect(controller.project.captionCue(id: id)?.displayName == "Caption: Original")
        #expect(controller.project.captionCue(id: id)?.isDraft == true)

        var cue = try #require(controller.project.captionCue(id: id))
        cue.text = "Updated"
        undo.beginUndoGrouping()
        try controller.updateCaptionCue(cue)
        undo.endUndoGrouping()
        #expect(controller.project.captionCue(id: id)?.text == "Updated")

        undo.beginUndoGrouping()
        try controller.deleteCaptionCue(id: id)
        undo.endUndoGrouping()
        #expect(controller.project.captionCue(id: id) == nil)
        undo.undo()
        #expect(controller.project.captionCue(id: id)?.text == "Updated")
    }

    @Test func finalizingCaptionsIsOneUndoableProjectChange() throws {
        let controller = controller()
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.installUndoManager(undo)
        undo.beginUndoGrouping()
        let id = try controller.addCaptionCue(
            start: ProjectTime(seconds: 2),
            end: ProjectTime(seconds: 4),
            text: "A complete caption passage"
        )
        undo.endUndoGrouping()
        #expect(controller.canFinalizeCaptions)

        undo.beginUndoGrouping()
        controller.finalizeCaptions()
        undo.endUndoGrouping()

        #expect(controller.project.captionCue(id: id)?.isDraft == false)
        #expect(!controller.canFinalizeCaptions)
        undo.undo()
        #expect(controller.project.captionCue(id: id)?.isDraft == true)
    }

    @Test func finalizationFailuresProduceDetailedResultsWithoutUsingPresentedError() throws {
        let controller = controller()
        let firstID = try controller.addCaptionCue(
            start: ProjectTime(seconds: 1),
            end: ProjectTime(seconds: 2),
            text: "One two three four"
        )
        _ = try controller.addCaptionCue(
            start: ProjectTime(seconds: 2.2),
            end: ProjectTime(seconds: 4),
            text: "Next caption"
        )

        controller.finalizeCaptions()

        let report = try #require(controller.captionFinalizationReport)
        #expect(controller.presentedError == nil)
        #expect(report.finalizedPassages == 1)
        #expect(report.issues.count == 1)
        #expect(report.issues[0].cueID == firstID)
        #expect(report.issues[0].displayName == "Caption: One two three four")
        #expect(report.issues[0].requiredDuration != nil)

        controller.dismissCaptionFinalizationReport()
        controller.revealCaptionFinalizationIssue(firstID)
        #expect(controller.activeTimelineTrackID == controller.project.captionTrack?.id)
        #expect(controller.selectedCaptionCueID == firstID)
        #expect(controller.timelineFocusRestoreTarget == .caption(firstID))
        #expect(controller.timelineFocusRestoreRequest == 1)
    }

    @Test func captionsCannotExtendPastProjectMedia() {
        let controller = controller()
        #expect(throws: CaptionFileError.self) {
            try controller.addCaptionCue(
                start: ProjectTime(seconds: 19),
                end: ProjectTime(seconds: 21),
                text: "Too late"
            )
        }
    }

    @Test func audioExportsDefaultToACaptionSidecar() {
        let audio = ExportFormatSelectionModel(selectedFormat: .wav, hasCaptions: true)
        #expect(audio.captionDelivery == .webVTT)

        let video = ExportFormatSelectionModel(selectedFormat: .h264MP4, hasCaptions: true)
        #expect(video.captionDelivery == .burnedIn)
        video.selectedFormat = .wav
        #expect(video.captionDelivery == .webVTT)
    }

    @Test func captionWindowSessionCanSaveAndFinishExactlyOnce() {
        var savedText: String?
        var closeCount = 0
        var finishCount = 0
        let caption = CaptionEditorWindowSession(
            cue: nil,
            range: ProjectTimeRange(
                start: ProjectTime(seconds: 1),
                duration: ProjectTime(seconds: 2)
            ),
            save: { savedText = $0 },
            play: {},
            finished: { finishCount += 1 }
        )
        caption.closeAction = { closeCount += 1 }

        caption.text = "Coffee is ready."
        caption.save()
        caption.finishOnce()
        caption.finishOnce()

        #expect(savedText == "Coffee is ready.")
        #expect(closeCount == 1)
        #expect(finishCount == 1)
    }
}
