import Foundation
@testable import Trimato

@main struct MediaDeletionCheck {
    @MainActor static func main() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("original media".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let segment = SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 3)))
        let removed = MediaAssetRecord(name: "Kitchen AD", originalPath: file.path, duration: ProjectTime(seconds: 3), hasAudio: true, sourceEdit: [segment])
        var retained = removed
        retained.id = UUID()
        var project = TrimatoProject()
        project.media = [removed, retained]
        project.folders = [ProjectFolder(name: "Recordings", assetIDs: [removed.id, retained.id])]
        let track = project.createTrack(kind: .audio, name: "Description")
        let first = try project.append(asset: removed, segments: [segment], toTrack: track)
        let second = try project.append(asset: removed, segments: [segment], toTrack: track)
        let survivor = try project.append(asset: retained, segments: [segment], toTrack: track)
        let otherTrack = project.createTrack(kind: .audio, name: "Voice")
        _ = try project.append(asset: removed, segments: [segment], toTrack: otherTrack)
        project.transitions = [TimelineTransition(trackID: track, edge: .between, kind: .audio(.crossFade), duration: ProjectTime(seconds: 1), leadingClipID: first, trailingClipID: second)]
        let elements = project.track(id: track)!.sortedClips.map { TimelineListElement(content: .clip($0)) }
        precondition(TimelineElementSequence.focusTargetAfterDeletingMedia(removed.id, clipID: first, from: elements) == .clip(survivor))
        precondition(TimelineElementSequence.focusTargetAfterDeletingMedia(removed.id, clipID: second, from: Array(elements.prefix(2))) == nil)
        let document = ProjectDocument(project: project)
        let controller = ProjectController(document: document)
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.installUndoManager(undo)
        controller.selection = .timelineClip(second)
        undo.beginUndoGrouping()
        controller.deleteSourceAsset(removed.id)
        undo.endUndoGrouping()
        precondition(document.hasUnsavedChanges)
        precondition(controller.selection == .project)
        precondition(document.project.asset(id: removed.id) == nil)
        precondition(document.project.asset(id: retained.id) != nil)
        precondition(document.project.sourceAssetTimelineUseCount(removed.id) == 0)
        precondition(document.project.timelineClip(id: survivor) != nil)
        precondition(document.project.transitions.isEmpty)
        precondition(document.project.folders[0].assetIDs == [retained.id])
        precondition(undo.undoActionName == "Delete Media")
        undo.undo()
        precondition(document.project == project && !document.hasUnsavedChanges)
        undo.redo()
        precondition(document.hasUnsavedChanges && document.project.asset(id: removed.id) == nil)
        undo.undo()
        undo.beginUndoGrouping()
        controller.deleteTimelineClip(id: first, selecting: .project)
        undo.endUndoGrouping()
        precondition(document.project.asset(id: removed.id) != nil)
        precondition(document.project.timelineClip(id: second) != nil)
        precondition(document.project.timelineClip(id: first) == nil)
        precondition(undo.undoActionName == "Remove from Timeline")
        undo.undo()
        precondition(document.project == project && !document.hasUnsavedChanges)
        let remainingData = try Data(contentsOf: file)
        precondition(remainingData == Data("original media".utf8))
        print("Media deletion: all uses, transitions, same-named source isolation, focus fallback, selection, dirty state, Undo/Redo, timeline-only removal, and original file preservation passed.")
    }
}
