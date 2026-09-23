import AppKit
import Combine
@testable import Trimato

@main struct MixerResponsivenessCheck {
    @MainActor static func main() {
        precondition(NSApp == nil)
        var focusQueries = 0
        func focusedElement() -> NSObject? { focusQueries += 1; return nil }
        for modifiers: NSEvent.ModifierFlags in [[.control, .option], [.command], [.shift], []] {
            for key: UInt16 in [123, 124, 125, 126, 48, 49] {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                    timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                    isARepeat: false, keyCode: key)!
                let before = focusQueries
                _ = SettingsSliderKeyboard.handle(event, focused: focusedElement())
                let adjusts = modifiers.isEmpty && (key == 125 || key == 126)
                precondition(focusQueries - before == (adjusts ? 1 : 0), "Unrelated navigation queried accessibility focus")
            }
        }
        print("PASS: VoiceOver and unrelated navigation keys bypass accessibility focus queries; plain Up/Down retain slider handling")
        for count in [100, 1000] {
            let segments = [SourceSegment(sourceRange: .init(start: .zero, duration: ProjectTime(seconds: 2)))]
            let clips = (0..<count).reversed().map { index in
                TimelineClip(assetID: UUID(), name: "Clip \(index)", segments: segments,
                             timelineStart: ProjectTime(seconds: Double(index) * 2))
            }
            let track = TimelineTrack(name: "Audio", kind: .audio, clips: clips)
            var project = TrimatoProject(name: "Playback cost check")
            project.tracks = [track]
            let controller = ProjectController(document: ProjectDocument(project: project))
            let clock = ProjectPlaybackClock()
            var durations: [Double] = []
            var updates = 0
            let observation = controller.objectWillChange.sink { updates += 1 }
            for tick in 1...600 {
                let time = ProjectTime(seconds: Double(tick % 300) / 10)
                let start = ContinuousClock.now
                clock.update(time, frameRate: 30)
                controller.updatePlaybackPosition(time, isPlaying: true)
                let elapsed = start.duration(to: .now).components
                durations.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            }
            durations.sort()
            print("\(count) clips, 600 clock/position updates: median \(durations[300]) ms, p95 \(durations[570]) ms, max \(durations.last!) ms; workspace updates \(updates)")
            withExtendedLifetime(observation) {}
            // Compare overlapping clips, equal starts, gaps and endpoints against
            // the original ordered-first semantics, independent of storage order.
            for position in [0.0, 1.9, 2, 15.5, Double(count) * 2, -1] {
                let time = ProjectTime(seconds: position)
                let reference = track.sortedClips.first { time >= $0.visibleTimelineStart && time < $0.visibleTimelineEnd }
                precondition(controller.currentTimelineClip(at: time)?.id == reference?.id)
            }
        }
        let segments = [SourceSegment(sourceRange: .init(start: .zero, duration: ProjectTime(seconds: 5)))]
        let overlaps = (0..<20).map { index in
            TimelineClip(assetID: UUID(), name: "Overlap", segments: segments,
                         timelineStart: ProjectTime(seconds: Double(index % 4)))
        }
        var overlappingProject = TrimatoProject()
        let overlappingTrack = TimelineTrack(name: "Overlapping", kind: .audio, clips: overlaps)
        overlappingProject.tracks = [overlappingTrack]
        let overlappingController = ProjectController(document: ProjectDocument(project: overlappingProject))
        for tick in 0...90 {
            let time = ProjectTime(seconds: Double(tick) / 10)
            let expected = overlappingTrack.sortedClips.first { time >= $0.visibleTimelineStart && time < $0.visibleTimelineEnd }
            precondition(overlappingController.currentTimelineClip(at: time)?.id == expected?.id)
        }
        print("PASS: clip lookup preserves overlap ordering, tied starts, gaps and endpoints")
        precondition(NSApp == nil)
    }
}
