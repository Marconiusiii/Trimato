import Combine
import Foundation
import Darwin
@testable import Trimato

/// Exercises model notifications only. Does not create views, windows, or play media.
@main struct ProjectDisplayUpdatesCheck {
    @MainActor static func main() {
        let model = ProjectPlayerViewModel()
        let duration = ProjectTime(seconds: 830.0673)
        let position = ProjectTime(seconds: 240)
        model.stageInsertionPlayhead(position, duration: duration)
        var frameUpdates = 0
        var timecodeUpdates = 0
        let frame = model.$currentFrame.dropFirst().sink { _ in frameUpdates += 1 }
        let timecode = model.$displayTimecode.dropFirst().sink { _ in timecodeUpdates += 1 }
        for _ in 0..<100 { model.stageInsertionPlayhead(position, duration: duration) }
        print("Repeated unchanged position: \(frameUpdates) frame notifications, \(timecodeUpdates) timecode notifications")
        guard frameUpdates == 0, timecodeUpdates == 0 else { exit(1) }
        model.stageInsertionPlayhead(ProjectTime(seconds: 241), duration: duration)
        guard frameUpdates == 1, timecodeUpdates == 1, model.currentTime.seconds == 241 else { exit(2) }
        withExtendedLifetime((frame, timecode)) {}
        print("PASS: changed position updates both displays; unchanged position does not publish")
    }
}
