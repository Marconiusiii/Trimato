import AppKit
import AVFoundation
import Testing
@testable import Trimato

@MainActor
@Suite(.serialized)
struct EditPointAdjustmentTests {
    private func time(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 48_000) }

    private func input(frames: Bool = false) -> ClipEditPointInput {
        let timeline = ClipEditTimeline(sourceRanges: [
            CMTimeRange(start: .zero, end: time(2)),
            CMTimeRange(start: time(4), end: time(7)),
            CMTimeRange(start: time(9), end: time(12))
        ])
        return ClipEditPointInput(generation: UUID(), timeline: timeline, point: timeline.editPoints[0],
            sourceDuration: time(12), frameRate: 24, frames: frames)
    }

    @Test func numberedJoinsUseTimelineOrderAndSurviveMarkerCollisions() throws {
        let input = input()
        #expect(input.timeline.editPoints.map(\.name) == ["Edit Point 1", "Edit Point 2"])
        let points = VideoPlayerViewModel.orderedTimelinePoints(duration: input.timeline.duration,
            inMarker: time(2), outMarker: nil, sourceRanges: input.timeline.sourceRanges)
        #expect(points.map(\.spokenName) == ["Start", "In, Edit Point 1", "Edit Point 2", "End"])
        for forward in [true, false] {
            var current = forward ? CMTime.zero : input.timeline.duration
            var names: [String] = []
            while let next = VideoPlayerViewModel.timelineDestination(from: current, movingForward: forward,
                duration: input.timeline.duration, inMarker: nil, outMarker: nil,
                sourceRanges: input.timeline.sourceRanges) {
                if next.editNumber != nil { names.append(next.spokenName) }
                current = next.time
            }
            #expect(names == (forward ? ["Edit Point 1", "Edit Point 2"] : ["Edit Point 2", "Edit Point 1"]))
        }
        var trimmed = input.timeline
        try trimmed.delete(editedRange: CMTimeRange(start: .zero, end: time(2)))
        #expect(trimmed.editPoints.map(\.name) == ["Edit Point 1"])
    }

    @Test func adjustmentChangesBothSidesAndKeepsOtherCuts() throws {
        let input = input()
        let changed = try input.validatedTimeline(inText: "00:00:02.250", outText: "00:00:03.750")
        #expect(changed.sourceRanges[0].end == time(2.25))
        #expect(changed.sourceRanges[1].start == time(3.75))
        #expect(changed.sourceRanges[1].end == time(7))
        #expect(changed.sourceRanges[2] == input.timeline.sourceRanges[2])
        #expect(changed.editPoints.map(\.time.seconds) == [2.25, 5.5])
        #expect(changed.duration == time(8.5))
    }

    @Test(arguments: ["garbage", "", "00:60:00", "00:00:60", "00:00:NaN", "-00:00:01", "00:00:13", "99:00:00", "00:00:1.2.3"])
    func invalidSourceTimecodesIdentifyTheirField(text: String) {
        let input = input()
        do {
            _ = try input.validatedTimeline(inText: text, outText: "00:00:04.000")
            Issue.record("Expected invalid In timecode")
        } catch let validation as ClipEditPointValidation {
            #expect(validation.inMessage?.contains("In") == true)
            #expect(validation.outMessage == nil)
        } catch { Issue.record("Expected a field validation error: \(error)") }
        do {
            _ = try input.validatedTimeline(inText: "00:00:02.000", outText: text)
            Issue.record("Expected invalid Out timecode")
        } catch let validation as ClipEditPointValidation {
            #expect(validation.outMessage?.contains("Out") == true)
        } catch { Issue.record("Expected a field validation error: \(error)") }
    }

    @Test func equalReversedAndCrossingBoundariesAreRejected() {
        let input = input()
        for (inText, outText) in [("00:00:04.000", "00:00:04.000"),
                                  ("00:00:05.000", "00:00:04.000")] {
            do {
                _ = try input.validatedTimeline(inText: inText, outText: outText)
                Issue.record("Expected reversed boundary rejection")
            } catch let validation as ClipEditPointValidation {
                #expect(validation.inMessage == "In must be earlier than Out.")
            } catch { Issue.record("Expected field validation") }
        }
        for (inText, outText, field) in [("00:00:00.000", "00:00:04.000", "In"),
                                         ("00:00:02.000", "00:00:07.000", "Out"),
                                         ("00:00:02.000", "00:00:09.000", "Out")] {
            do {
                _ = try input.validatedTimeline(inText: inText, outText: outText)
                Issue.record("Expected neighboring-section rejection")
            } catch let validation as ClipEditPointValidation {
                #expect((field == "In" ? validation.inMessage : validation.outMessage) != nil)
            } catch { Issue.record("Expected field validation") }
        }
        let second = ClipEditPointInput(generation: input.generation, timeline: input.timeline,
            point: input.timeline.editPoints[1], sourceDuration: input.sourceDuration, frameRate: 24, frames: false)
        do {
            _ = try second.validatedTimeline(inText: "00:00:03.000", outText: "00:00:09.000")
            Issue.record("Expected rejection of a boundary crossing the previous cut")
        } catch let validation as ClipEditPointValidation {
            #expect(validation.inMessage?.contains("later than 00:00:04.000") == true)
        } catch { Issue.record("Expected field validation") }
    }

    @Test func frameInputAndUnchangedFractionalBoundariesKeepPrecision() throws {
        let framed = input(frames: true)
        let changed = try framed.validatedTimeline(inText: "49", outText: "95")
        #expect(abs(changed.editPoints[0].inTime.seconds - 49.0 / 24) < 0.000001)
        #expect(abs(changed.editPoints[0].outTime.seconds - 95.0 / 24) < 0.000001)
        let inTime = CMTime(value: 96_001, timescale: 48_000)
        let outTime = CMTime(value: 192_007, timescale: 48_000)
        let timeline = ClipEditTimeline(sourceRanges: [CMTimeRange(start: .zero, end: inTime),
            CMTimeRange(start: outTime, end: time(7))])
        for frames in [true, false] {
            let input = ClipEditPointInput(generation: UUID(), timeline: timeline, point: timeline.editPoints[0],
                sourceDuration: time(7), frameRate: 24, frames: frames)
            let unchanged = try input.validatedTimeline(inText: input.timeInput(inTime).initialText,
                outText: input.timeInput(outTime).initialText)
            #expect(unchanged == timeline)
        }
    }

    @Test(arguments: ["1.5", "-1", "NaN", "289"])
    func invalidFramesIdentifyTheField(text: String) {
        do {
            _ = try input(frames: true).validatedTimeline(inText: text, outText: "96")
            Issue.record("Expected invalid frame rejection")
        } catch let validation as ClipEditPointValidation {
            #expect(validation.inMessage?.contains("whole frame number") == true)
        } catch { Issue.record("Expected field validation") }
    }

    private func loadedPlayer() async throws -> (VideoPlayerViewModel, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData![0].update(repeating: 0, count: Int(buffer.frameLength))
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let model = VideoPlayerViewModel(announcementHandler: { _ in })
        model.player.isMuted = true
        let source = MediaSource.native(url: url, asset: AVURLAsset(url: url), contentType: nil,
            mode: .nativePassthrough, hasVideo: false, hasAudio: true)
        model.load(url: url, sourceSegments: [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 0.5))),
            SourceSegment(sourceRange: ProjectTimeRange(start: ProjectTime(seconds: 0.75), duration: ProjectTime(seconds: 0.5))),
            SourceSegment(sourceRange: ProjectTimeRange(start: ProjectTime(seconds: 1.5), duration: ProjectTime(seconds: 0.5)))], preparedSource: source)
        for _ in 0..<500 where model.isLoadingMedia { try await Task.sleep(for: .milliseconds(10)) }
        try #require(model.hasMedia && !model.isLoadingMedia)
        model.showingFrames = false
        model.scopeKeyboardCommands { true }
        model.goToStart(); model.goToNextTimelinePoint()
        return (model, url)
    }

    @Test func enterOnlyOpensFromThePlayheadAndCancelKeepsTheEdit() async throws {
        let (model, url) = try await loadedPlayer()
        defer { model.closeMedia(); try? FileManager.default.removeItem(at: url) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let text = NSTextView(frame: window.contentLayoutRect)
        window.contentView = text; window.makeFirstResponder(text)
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        #expect(model.handleKeyEvent(enter) === enter)
        #expect(model.editPointInput == nil)
        let slider = NativePlayheadSlider.PlayheadSlider()
        window.contentView = slider; window.makeFirstResponder(slider)
        #expect(model.handleKeyEvent(enter) == nil)
        let request = try #require(model.editPointInput)
        #expect(request.point.name == "Edit Point 1")
        #expect(request.point.inTime == time(0.5))
        #expect(request.point.outTime == time(0.75))
        let before = model.placementSourceSegments
        model.editPointInput = nil
        #expect(model.placementSourceSegments == before)
        #expect(model.duration == 1.5)
        #expect(model.handleKeyEvent(enter) == nil)
        let reopened = try #require(model.editPointInput)
        let adjusted = try reopened.validatedTimeline(inText: "00:00:00.550", outText: "00:00:00.700")
        let nativeUndo = try #require(window.undoManager)
        nativeUndo.groupsByEvent = false
        nativeUndo.beginUndoGrouping()
        // The key route supplies the actual window's manager when no SwiftUI environment manager is available.
        try await model.applyEditPoint(reopened, timeline: adjusted, undoManager: nil)
        nativeUndo.endUndoGrouping()
        #expect(nativeUndo.canUndo)
        nativeUndo.undo()
        #expect(model.placementSourceSegments.map(\.sourceRange) == before.map(\.sourceRange))
        model.editPointInput = nil
        model.goToStart()
        #expect(model.handleKeyEvent(enter) === enter)
    }

    @Test func applyingJoinSupportsUndoRedoAndCancelledPreparation() async throws {
        let (model, url) = try await loadedPlayer()
        defer { model.closeMedia(); try? FileManager.default.removeItem(at: url) }
        #expect(model.prepareEditPoint())
        let request = try #require(model.editPointInput)
        let changed = try request.validatedTimeline(inText: "00:00:00.550", outText: "00:00:00.700")
        let before = model.placementSourceSegments
        let undo = UndoManager(); undo.groupsByEvent = false
        let cancelled = Task { try await model.applyEditPoint(request, timeline: changed, undoManager: undo) }
        cancelled.cancel()
        do { try await cancelled.value; Issue.record("Expected cancellation") } catch is CancellationError { }
        #expect(model.placementSourceSegments == before)
        #expect(!model.isApplyingEdit)
        #expect(!undo.canUndo)
        undo.beginUndoGrouping()
        try await model.applyEditPoint(request, timeline: changed, undoManager: undo)
        undo.endUndoGrouping()
        #expect(abs(model.duration - 1.6) < 0.000001)
        #expect(model.currentTime == 0.55)
        #expect(undo.undoActionName == "Adjust Edit Point 1")
        let after = model.placementSourceSegments
        undo.undo()
        #expect(model.placementSourceSegments.map(\.sourceRange) == before.map(\.sourceRange))
        #expect(model.duration == 1.5)
        undo.redo()
        #expect(model.placementSourceSegments.map(\.sourceRange) == after.map(\.sourceRange))
        #expect(abs(model.duration - 1.6) < 0.000001)
        do {
            try await model.applyEditPoint(request, timeline: changed, undoManager: undo)
            Issue.record("Expected stale edit-point rejection")
        } catch { #expect(error.localizedDescription.contains("clip has changed")) }
    }
}
