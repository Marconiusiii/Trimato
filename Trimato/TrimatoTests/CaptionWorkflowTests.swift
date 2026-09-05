import AppKit
import Foundation
import Testing
@testable import Trimato

@Suite(.serialized)
@MainActor
struct CaptionWorkflowTests {
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

    @Test func captionSheetCanCloseAndOpenAgainOnTheSameProjectWindow() async {
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        await presentAndCloseCaptionSheet(on: parent)
        #expect(parent.attachedSheet == nil)

        await presentAndCloseCaptionSheet(on: parent)
        #expect(parent.attachedSheet == nil)
    }

    private func presentAndCloseCaptionSheet(on parent: NSWindow) async {
        let caption = CaptionEditorWindowController(
            cue: nil,
            range: ProjectTimeRange(
                start: ProjectTime(seconds: 1),
                duration: ProjectTime(seconds: 2)
            ),
            save: { _ in },
            play: {},
            cancel: {}
        )

        await withCheckedContinuation { continuation in
            caption.present(asSheetOf: parent) {
                continuation.resume()
            }
            #expect(parent.attachedSheet === caption.window)
            caption.closeSheet()
        }
    }
}
