import Foundation
import AppKit
import Darwin
import AVFoundation
import Combine
@testable import Trimato

@main struct ClipReadyAnnouncementCheck {
    static func verify(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL: \(message)"); exit(1) }
    }

    @MainActor static func main() async throws {
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
