import AppKit
import SwiftUI
import Testing
@testable import TrimatoMediaSupport

struct MixerLayoutTests {
    @Test @MainActor func playheadLayoutStaysBoundedForLongProjects() {
        // Offscreen hosting only: no application launch, window, or focus changes.
        for frames in [6_000.0, 216_000.0, 1_000_000.0] {
            let start = Date()
            let host = NSHostingView(rootView:
                MixerPlayheadSlider(value: .constant(0), step: 1 / frames, timecode: "00:00:00:00")
                    .frame(width: 580))
            host.frame = NSRect(x: 0, y: 0, width: 580, height: 50)
            let size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            let elapsed = Date().timeIntervalSince(start)
            #expect(size.width == 580)
            #expect(size.height > 0 && size.height < 100)
            #expect(elapsed < 1, "Playhead with \(frames) frame steps took \(elapsed) seconds")
        }
    }
}
