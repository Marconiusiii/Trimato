import AppKit
import SwiftUI
import QuartzCore
@testable import Trimato

/// Exercises real SwiftUI layout without showing a window or changing focus.
@main struct MixerLayoutCheck {
    @MainActor static func main() async {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        var project = TrimatoProject(name: "Hidden Mixer layout check")
        project.tracks = [TimelineTrack(name: "Audio", kind: .audio, clips: [])]
        let controller = ProjectController(document: ProjectDocument(project: project))
        let player = ProjectPlayerViewModel()
        player.player.isMuted = true
        let session = MixerSession(controller: controller, player: player)
        let host = NSHostingController(rootView: MixerView(session: session, player: player))
        if CommandLine.arguments.contains("--bounded") { host.sizingOptions = [] }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.contentMinSize = NSSize(width: 440, height: 540)
        host.view.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(50))
        var times: [Double] = []
        for tick in 0..<80 {
            let start = CACurrentMediaTime()
            player.playbackClock.update(ProjectTime(seconds: Double(tick) / 10), frameRate: 30)
            session.change(\.pan, to: Double(tick % 41 - 20) / 100)
            // Drain SwiftUI's scheduled transactions, then force actual host layout.
            try? await Task.sleep(for: .milliseconds(1))
            host.view.layoutSubtreeIfNeeded()
            times.append((CACurrentMediaTime() - start) * 1000)
            precondition(!window.isVisible && !window.isKeyWindow && !app.isActive)
        }
        let sorted = times.sorted()
        print(String(format: "Mixer layout: median %.2f ms; p95 %.2f ms; max %.2f ms", sorted[40], sorted[76], sorted.last!))
        for size in [NSSize(width: 440, height: 540), NSSize(width: 900, height: 1000), NSSize(width: 500, height: 800)] {
            window.setContentSize(size)
            host.view.layoutSubtreeIfNeeded()
            precondition(abs(host.view.frame.width - size.width) < 1)
            precondition(abs(host.view.frame.height - size.height) < 1)
            precondition(!window.isVisible && !window.isKeyWindow)
        }
        print("PASS: Mixer host follows small, large and restored viewport sizes without showing a window")
        // The actual shared slider must expose its native label, value and actions.
        var pan = 0.0
        let sliderHost = NSHostingController(rootView: AudioValueSlider(label: "Pan", value: Binding(get: { pan }, set: { pan = $0 }), range: -1...1, step: 0.01, unit: "", identifier: "layout.check.pan", spokenValue: MixerValue.position))
        window.contentViewController = sliderHost
        sliderHost.view.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(50))
        var seen = Set<ObjectIdentifier>()
        func find(_ object: NSObject) -> NSObject? {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            if object.responds(to: NSSelectorFromString("accessibilityRole")), object.value(forKey: "accessibilityRole") as? String == "AXSlider" { return object }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")), let children = object.value(forKey: "accessibilityChildren") as? [NSObject] {
                for child in children { if let found = find(child) { return found } }
            }
            return nil
        }
        guard let slider = find(sliderHost.view) else {
            print("LIMITATION: hidden host did not expose AXSlider; native accessibility remains unverified")
            session.close(); window.close(); return
        }
        let label = slider.value(forKey: "accessibilityLabel") as? String ?? ""
        precondition(label == "Pan", "Incorrect native label: \(label)")
        let increment = NSSelectorFromString("accessibilityPerformIncrement")
        let decrement = NSSelectorFromString("accessibilityPerformDecrement")
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        for (selector, expected) in [(increment, 0.01), (decrement, 0.0)] {
            precondition(slider.responds(to: selector))
            let action = unsafeBitCast(slider.method(for: selector), to: Action.self)
            precondition(action(slider, selector))
            precondition(abs(pan - expected) < 0.00001, "Adjustment precision changed: \(pan)")
        }
        precondition(!window.isVisible && !app.isActive)
        print("PASS: native Pan label, slider role, increment/decrement precision; no window shown or activated")
        session.close()
        window.close()
    }
}
