import AppKit
import SwiftUI
import Testing
@testable import Trimato

@MainActor
@Suite(.serialized)
struct ToolPanePresentationTests {
    private func attribute(_ item: NSObject, _ key: String) -> Any? {
        item.responds(to: NSSelectorFromString(key)) ? item.value(forKey: key) : nil
    }

    private func descendants(_ item: NSObject) -> [NSObject] {
        [item] + ((attribute(item, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(descendants)
    }

    private func title(_ item: NSObject) -> String {
        for key in ["accessibilityTitle", "accessibilityLabel", "accessibilityValue"] {
            if let value = attribute(item, key) as? String, !value.isEmpty { return value }
        }
        return ""
    }

    @Test(arguments: ["Captioner", "Describer", "Voicer", "Mixer"], [720.0, 850.0])
    func actionsRemainVisibleAndHelpIsLast(tool: String, height: Double) async throws {
        let controller = ProjectController(document: ProjectDocument())
        let player = ProjectPlayerViewModel()
        let recording = ProjectRecordingSession(controller: controller,
            purpose: tool == "Describer" ? .audioDescription : .voiceOver, prepareCapture: {})
        let caption = CaptionEditorWindowSession(cue: nil,
            range: ProjectTimeRange(start: ProjectTime(seconds: 2), duration: ProjectTime(seconds: 3)),
            save: { _ in }, play: {}, finished: {})
        caption.text = "Pour the water slowly over the coffee."
        let mixer = MixerSession(controller: controller, player: player)
        let content: AnyView
        switch tool {
        case "Captioner": content = AnyView(CaptionEditorView(session: caption, focusRevision: 0, cancel: {}))
        case "Mixer": content = AnyView(MixerView(session: mixer, player: player))
        default: content = AnyView(ProjectRecordingView(session: recording))
        }
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: height),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close(); recording.close(); mixer.close(restoreFocus: false) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        func checkScrollAreas() {
            let scrollAreas = descendants(host).filter { attribute($0, "accessibilityRole") as? String == "AXScrollArea" }
            for area in scrollAreas {
                let nested = descendants(area)
                #expect(nested.contains { attribute($0, "accessibilityRole") as? String == "AXTextArea" },
                        "Only native text editing may have a scroll area")
                #expect(!nested.contains { attribute($0, "accessibilityRole") as? String == "AXButton" },
                        "Pane buttons must not be enclosed by a scroll area")
            }
        }
        checkScrollAreas()
        let controls = descendants(host).filter {
            ["AXButton", "AXTextField", "AXTextArea", "AXSlider", "AXCheckBox", "AXDisclosureTriangle",
             "AXPopUpButton", "AXMenuButton"].contains(attribute($0, "accessibilityRole") as? String ?? "")
        }
        #expect(controls.last.map(title) == "Help")
        let footerTitles = tool == "Mixer" ? ["Close", "Help"]
            : ["Cancel", tool == "Captioner" ? "Add Caption" : recording.saveTitle, "Help"]
        let hostFrame = try #require(attribute(host, "accessibilityFrame") as? NSValue).rectValue
        for name in footerTitles {
            let control = try #require(controls.first { title($0) == name })
            let rect = try #require(attribute(control, "accessibilityFrame") as? NSValue).rectValue
            #expect(hostFrame.insetBy(dx: -1, dy: -1).contains(rect), "Footer outside pane: \(name)")
            #expect(rect.minY < hostFrame.minY + 70, "Footer must remain at the bottom")
        }
        #expect(host.fittingSize.width <= 441)
        func checkControlBounds() throws {
            let bounds = try #require(attribute(host, "accessibilityFrame") as? NSValue).rectValue
            for control in descendants(host) where ["AXButton", "AXTextField", "AXTextArea", "AXSlider", "AXCheckBox", "AXDisclosureTriangle"].contains(attribute(control, "accessibilityRole") as? String ?? "") {
                let rect = try #require(attribute(control, "accessibilityFrame") as? NSValue).rectValue
                if rect.width > 0 && rect.height > 0 {
                    #expect(bounds.insetBy(dx: -1, dy: -1).contains(rect), "Control outside pane: \(title(control))")
                }
            }
            #expect(host.frame.height <= height + 1, "Pane must fit the requested height")
        }
        try checkControlBounds()
        if tool == "Describer" || tool == "Voicer" {
            let adjustmentsTab = try #require(descendants(host).first { title($0) == "Voice Adjustments" } as? NSTabViewItem)
            let tabView = try #require(adjustmentsTab.tabView)
            tabView.selectTabViewItem(adjustmentsTab)
            try await Task.sleep(for: .milliseconds(250))
            try checkControlBounds()
            checkScrollAreas()
            recording.voice.evenOut = true
            try await Task.sleep(for: .milliseconds(250))
            try checkControlBounds()
        }
    }

    @Test func pausedClockReformatsImmediatelyWhenPrecisionChanges() async throws {
        let defaults = UserDefaults.standard
        let key = AppPreferenceKey.precisionTimecode
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        defaults.set(true, forKey: key)
        let clock = ProjectPlaybackClock()
        clock.time = ProjectTime(seconds: 85.125)
        clock.timecode = "00:01:25.125"
        let host = NSHostingView(rootView: ProjectLiveTimecode(clock: clock, showingFrames: false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        for (precision, expected) in [(true, "00:01:25.125"), (false, "1:25"), (true, "00:01:25.125")] {
            defaults.set(precision, forKey: key)
            try await Task.sleep(for: .milliseconds(250))
            #expect(descendants(host).contains { title($0) == expected })
            #expect(clock.time.seconds == 85.125)
        }
    }
}
