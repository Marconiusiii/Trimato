import Foundation
import Accessibility
import AppKit
import Darwin
import AVFoundation
import Combine
@testable import Trimato

@main struct ClipReadyAnnouncementCheck {
    static func verify(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL: \(message)"); exit(1) }
    }

    @MainActor static func checkPreviewReadiness() async throws {
        var renders: [URL: CheckedContinuation<URL, Error>] = [:]
        var callbacks: [URL: @MainActor @Sendable (Double) -> Void] = [:]
        var commits: [URL] = []
        let preview = ClipPreviewCoordinator(render: { request, progress in
            callbacks[request.source] = progress
            return try await withCheckedThrowingContinuation { renders[request.source] = $0 }
        }, prepare: { _, _ in AVMutableComposition() }, remove: { _ in })
        func request(_ name: String, filtered: Bool) -> ClipPreviewCoordinator.Request {
            .init(source: URL(fileURLWithPath: "/tmp/\(name).mov"),
                  filters: filtered ? [ClipFilter(kind: .blackAndWhite)] : [], audio: false,
                  segments: [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 1)))],
                  audioSettings: nil)
        }
        func update(_ request: ClipPreviewCoordinator.Request) {
            preview.update(request, debounce: false, readiness: { _ in }, restoreOriginal: {},
                           commit: { _, url, _ in commits.append(url) })
        }
        func waitFor(_ predicate: () -> Bool) async throws {
            for _ in 0..<1000 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(1))
            }
            verify(false, "Preview check timed out")
        }
        let original = request("original", filtered: false)
        verify(!preview.isReady(for: original) && !preview.isReady(for: nil), "Unstarted preview was ready")
        update(original)
        verify(preview.isReady(for: original), "Unfiltered preview was not ready")
        let first = request("first", filtered: true)
        let second = request("second", filtered: true)
        update(first)
        try await waitFor { renders[first.source] != nil }
        verify(!preview.isReady(for: first), "Rendering clip was ready")
        update(second)
        try await waitFor { renders[second.source] != nil }
        callbacks[second.source]?(0.4)
        callbacks[first.source]?(0.9)
        verify(preview.progress == 0.4, "Replaced preview posted stale progress")
        renders.removeValue(forKey: first.source)?.resume(returning: first.source)
        renders.removeValue(forKey: second.source)?.resume(returning: second.source)
        try await waitFor { preview.isReady(for: second) }
        verify(commits == [second.source] && !preview.isReady(for: first), "Stale preview became ready")
        update(first)
        try await waitFor { renders[first.source] != nil }
        preview.cancel()
        renders.removeValue(forKey: first.source)?.resume(returning: first.source)
        try await Task.sleep(for: .milliseconds(20))
        verify(!preview.isReady(for: first) && commits == [second.source], "Cancelled preview became ready")
        print("PASS: current preview readiness, effects preparation, cancellation, replaced requests, and stale progress")
    }

    @MainActor static func checkPreparationSheet() {
            for outcome in [OperationProgressOutcome.completed, .cancelled, .failed] {
                let sheet = ClipPreparationSheetPresentation(postsAnnouncements: false)
                var handoffs = 0
                var cancellations = 0
                let operation = OperationProgress.clipLoading(progress: 0.2, stage: "Indexing frames", cancel: { cancellations += 1 })
                sheet.synchronize(operation: operation, outcome: .completed, completionPending: false) { handoffs += 1 }
                guard let session = sheet.session else { fatalError("Sheet session missing") }
                verify(sheet.isPresented && handoffs == 0, "Sheet did not block entry")
                sheet.synchronize(operation: .clipLoading(progress: 0.6, stage: "Indexing frames", cancel: { cancellations += 1 }),
                    outcome: .completed, completionPending: false) { handoffs += 1 }
                verify(sheet.session === session && session.progress == 0.6, "Progress replaced the presentation or lost measured value")
                sheet.synchronize(operation: nil, outcome: .completed, completionPending: true) { handoffs += 1 }
                verify(sheet.isPresented && !session.isFinished, "Effects readiness gap dismissed preparation")
                if outcome == .cancelled { session.cancel(); session.cancel() }
                verify(cancellations == (outcome == .cancelled ? 1 : 0), "Cancellation was not delivered once")
                sheet.synchronize(operation: nil, outcome: outcome, completionPending: false) { handoffs += 1 }
                verify(handoffs == 0 && session.isFinished && session.outcome == outcome, "Completion released entry before native dismissal")
                verify(sheet.isPresented && handoffs == 0, "Model completed native dismissal itself")
                // Model-only check: SwiftUI's writable binding and onDismiss are
                // driven by the real framework in the separate hosted check.
                sheet.isPresented = false
                session.update(operation)
                verify(session.progress == 0.6, "Late progress updated the finished sheet")
                sheet.sheetDismissed(); sheet.sheetDismissed()
                sheet.synchronize(operation: nil, outcome: outcome, completionPending: false) { handoffs += 1 }
                verify(handoffs == 1 && sheet.session == nil, "Dismissal handoff repeated or retained a stale session")
                var ready = ClipReadyAnnouncementPolicy()
                verify((ready.message(ready: true, outcome: outcome) != nil) == (outcome == .completed), "Unsuccessful sheet announced ready")
            }
        let quick = ClipPreparationSheetPresentation(postsAnnouncements: false)
        var handoffs = 0
        quick.synchronize(operation: nil, outcome: .completed, completionPending: true) { handoffs += 1 }
        quick.synchronize(operation: nil, outcome: .completed, completionPending: false) { handoffs += 1 }
        verify(handoffs == 1 && quick.session == nil && !quick.isPresented, "Quick load without a sheet lost entry")
        print("PASS: sheet model only: measured progress, effects readiness, cancellation, failure, late progress rejection, writable presentation state, and one handoff")
    }

    @MainActor static func main() async throws {
        checkPreparationSheet()
        verify(NSApp == nil, "Background check must not create an application")
        for outcome in [OperationProgressOutcome.completed, .cancelled, .failed] {
            var operation = OperationProgress(
                title: "Preparing Clip", detail: "Inspecting media",
                announceCompletion: false, announcesUpdates: false
            )
            let session = OperationProgressWindowSession(operation: operation, postsAnnouncements: false)
            operation.detail = "Preparing waveform"
            session.update(operation)
            var dismissed = false
            session.finish(outcome: outcome) { dismissed = true }
            operation.detail = "Stale loading status"
            session.update(operation)
            await Task.yield()
            verify(session.detail == "Preparing waveform", "Finished session accepted a late update")
            verify(session.isFinished && session.outcome == outcome, "Completion outcome changed")
            session.completeDismissal()
            verify(dismissed, "Completion lost the existing dismissal handoff")
        }
        var spoken: [AttributedString] = []
        var loading = OperationProgress.clipLoading(progress: nil, stage: "Identifying clip", cancel: {})
        let loadingSession = OperationProgressWindowSession(operation: loading,
            postsAnnouncements: false, announcementHandler: { spoken.append($0) })
        for stage in ["Identifying clip", "Preparing clip for playback", "Preparing playback"] {
            loading = .clipLoading(progress: nil, stage: stage, cancel: {})
            verify(loading.detail == nil && loading.title == "Preparing Clip", "Transient stage entered native loading text")
            loadingSession.update(loading)
        }
        verify(spoken.isEmpty, "Brief loading stages queued redundant speech")
        loading.progressStage = "Indexing frames"
        loading.progress = 0.3
        loadingSession.update(loading)
        loadingSession.update(loading)
        verify(spoken.map { String($0.characters) } == ["Indexing frames, 30 percent."], "Measured progress missing or repeated")
        verify(spoken.allSatisfy { $0.accessibilitySpeechAnnouncementPriority == .low }, "Loading priority must be low")
        loading.progress = nil
        loading.progressStage = "Preparing clip for playback"
        loadingSession.update(loading)
        var readyPolicy = ClipReadyAnnouncementPolicy()
        loadingSession.finish(outcome: .completed) {
            verify(loadingSession.isFinished, "Ready preceded loading lifecycle completion")
            if let ready = readyPolicy.announcement(ready: true, outcome: .completed) { spoken.append(ready) }
        }
        verify(spoken.count == 1, "Ready preceded the loading window handoff")
        loadingSession.completeDismissal()
        loadingSession.completeDismissal()
        loading.progress = 0.8
        loadingSession.update(loading)
        verify(spoken.map { String($0.characters) } == ["Indexing frames, 30 percent.", "Clip Ready"],
               "Late stage, duplicate ready, or incorrect announcement ordering")
        verify(spoken.last?.accessibilitySpeechAnnouncementPriority == .high, "Ready priority must be high")
        verify(readyPolicy.announcement(ready: true, outcome: .completed) == nil, "Ready repeated")
        for outcome in [OperationProgressOutcome.cancelled, .failed] {
            var messages: [AttributedString] = []
            let session = OperationProgressWindowSession(operation: .clipLoading(progress: nil, stage: nil, cancel: {}),
                postsAnnouncements: false, announcementHandler: { messages.append($0) })
            session.finish(outcome: outcome) {}
            session.update(.clipLoading(progress: 0.5, stage: "Preparing playback", cancel: {}))
            var ready = ClipReadyAnnouncementPolicy()
            verify(ready.announcement(ready: true, outcome: outcome) == nil, "Unsuccessful load announced ready")
            verify(messages.count == 1 && messages[0].accessibilitySpeechAnnouncementPriority == .high,
                   "Cancellation or failure priority/lifecycle was incorrect")
        }
        print("PASS: actual attributed announcement priorities, stable loading text, completion handoff, ordering, and late callback rejection")
        try await checkPreviewReadiness()
        var legacy = OperationProgressAnnouncements()
        verify(legacy.update(progress: 0.5) == "50 percent.", "Existing progress speech changed")
        verify(legacy.finish(outcome: .completed) == "100 percent, complete.", "Existing completion speech changed")
        var stages = OperationProgressAnnouncements()
        verify(stages.update(progress: 0.9, stage: "Indexing frames") == "90 percent.", "Index progress missing")
        verify(stages.update(progress: 1, stage: "Indexing frames") == nil, "Stage claimed overall completion")
        verify(stages.update(progress: 0, stage: "Creating playback proxy") == "0 percent.", "Proxy stage did not reset")
        verify(stages.update(progress: 0.1, stage: "Creating playback proxy") == "10 percent.", "Proxy milestone lost")
        verify(stages.update(progress: 0.11, stage: "Creating playback proxy") == nil, "Repeated milestone")
        verify(stages.update(progress: nil, stage: "Preparing playback") == nil, "Unknown work invented a percentage")
        verify(stages.finish(outcome: .completed, announceCompletion: false) == nil, "Duplicate generic completion")
        verify(stages.update(progress: 0.5, stage: "Old callback") == nil, "Progress followed completion")
        for invalid in [Double.nan, Double.infinity] {
            var progress = OperationProgressAnnouncements()
            verify(progress.update(progress: invalid, stage: "Preparing playback") == nil, "Invalid percentage spoken")
        }
        let quickLoad = ClipLoadingPresentation()
        quickLoad.begin()
        quickLoad.finish()
        let replacedLoad = ClipLoadingPresentation()
        replacedLoad.begin()
        replacedLoad.begin()
        replacedLoad.finish()
        let slowLoad = ClipLoadingPresentation()
        slowLoad.begin()
        verify(!slowLoad.isPresented, "Slow load showed progress immediately")
        await slowLoad.delayTask?.value
        verify(!quickLoad.isPresented, "Completed quick load showed delayed progress")
        verify(!replacedLoad.isPresented, "Replaced or cancelled load showed stale progress")
        verify(slowLoad.isPresented, "Long load did not show progress")
        slowLoad.finish()
        verify(slowLoad.isPresented, "Entry unblocked before the progress window returned")
        slowLoad.dismissed()
        verify(!slowLoad.isPresented, "Dismissal did not unblock entry")
        for cached in [true, false] {
            var entry = ClipEditorEntryFocusPolicy()
            var announcement = ClipReadyAnnouncementPolicy()
            if !cached {
                verify(!entry.consume(ready: false, isKeyWindow: true, hasSheet: true), "Entered while preparing")
            }
            verify(!entry.consume(ready: true, isKeyWindow: true, hasSheet: true), "Entered before progress dismissal")
            verify(!entry.consume(ready: true, isKeyWindow: false, hasSheet: false), "Entered an inactive window")
            verify(entry.consume(ready: true, isKeyWindow: true, hasSheet: false), "Ready entry was lost")
            verify(announcement.message(ready: true, outcome: .completed) == "Clip Ready", "Ready announcement was lost")
            verify(announcement.message(ready: true, outcome: .completed) == nil, "Repeated ready announcement")
            verify(!entry.consume(ready: true, isKeyWindow: true, hasSheet: false), "Later dismissal repeated entry")
        }
        for outcome in [OperationProgressOutcome.cancelled, .failed] {
            var announcement = ClipReadyAnnouncementPolicy()
            verify(announcement.message(ready: true, outcome: outcome) == nil, "Unsuccessful load announced ready")
        }
        var announcement = ClipReadyAnnouncementPolicy()
        verify(announcement.message(ready: false, outcome: .completed) == nil, "Unprepared clip announced ready")
        verify(announcement.message(ready: true, outcome: .completed) == "Clip Ready", "Early update consumed readiness")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trimato-loading-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("silent.mov")
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: [
            "-v", "error", "-nostdin", "-f", "lavfi", "-i", "color=c=black:s=64x64:r=10:d=1",
            "-c:v", "prores_ks", "-an", url.path
        ])
        let clip = VideoPlayerViewModel()
        clip.player.volume = 0
        var measured = false
        var playbackPreparation = false
        let progressObservation = clip.$mediaProgress.sink { value in
            if let value, value.isFinite { measured = true }
        }
        let statusObservation = clip.$mediaStatus.sink { status in
            if status == "Preparing playback" { playbackPreparation = true }
        }
        for prepared in [false, true] {
            let source: MediaSource? = prepared ? .native(
                url: url, asset: AVURLAsset(url: url), contentType: nil,
                mode: .nativePassthrough,
                frameTimestamps: (0..<10).map { CMTime(value: Int64($0), timescale: 10) },
                hasAudio: false
            ) : nil
            clip.load(url: url, preparedSource: source)
            for _ in 0..<1000 {
                if !clip.isPreparingMedia { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            verify(!clip.isPreparingMedia && clip.hasMedia && clip.duration > 0, "Real clip failed to become editable")
            verify(clip.mediaProgress == nil, "Ready clip retained a stale loading percentage")
            verify(clip.mediaPreparationOutcome == .completed, "Real load did not succeed")
            verify(clip.player.rate == 0, "Background check started playback")
            clip.closeMedia()
        }
        verify(measured && playbackPreparation, "Real loading omitted indexing or final preparation")
        withExtendedLifetime((progressObservation, statusObservation)) {}
        print("PASS: real silent video loads, measured indexing, final preparation, and prepared-source reopening")
        verify(NSApp == nil, "Background check created an application")
        print("PASS: quiet quick loads, delayed long loads, cancellation, dismissal gating, late update rejection, cached and uncached entry, progress dismissal, inactive window, one announcement, cancellation, and failure")
    }
}
