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

extension MixerLayoutTests {
    @Test @MainActor func nativeTrackSlidersHaveBoundedLayout() {
        let start = Date()
        let host = NSHostingView(rootView: VStack {
            AudioValueSlider(label: "Volume", value: .constant(-6), range: -60...12, step: 0.5,
                unit: "dB", identifier: "test.volume", spokenValue: MixerValue.decibels)
            AudioValueSlider(label: "Pan", value: .constant(-0.25), range: -1...1, step: 0.01,
                unit: "", identifier: "test.pan", spokenValue: MixerValue.position)
            AudioValueSlider(label: "Stereo balance", value: .constant(0.25), range: -1...1, step: 0.01,
                unit: "", identifier: "test.balance", spokenValue: MixerValue.position)
            AudioValueSlider(label: "Stereo width", value: .constant(1), range: 0...2, step: 0.01,
                unit: "", identifier: "test.width", spokenValue: MixerValue.width)
        }.frame(width: 720))
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 160)
        let size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        #expect(size.width == 720 && size.height > 0 && size.height < 200)
        #expect(Date().timeIntervalSince(start) < 1)
    }
    @Test func mixerValuesDescribeUnitsAndDirection() {
        #expect(MixerValue.decibels(-6) == "-6.0 dB")
        #expect(MixerValue.position(0) == "Center")
        #expect(MixerValue.position(-0.25) == "25 percent left")
        #expect(MixerValue.position(0.5) == "50 percent right")
        #expect(MixerValue.width(0) == "Mono")
        #expect(MixerValue.width(1) == "Original")
        #expect(MixerValue.width(1.5) == "150 percent")
    }
}
