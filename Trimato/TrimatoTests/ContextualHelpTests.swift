import AppKit
import SwiftUI
import Foundation
import Testing
@testable import Trimato

@MainActor
@Suite(.serialized)
struct ContextualHelpTests {
    @Test(arguments: [TrimatoHelp.Topic.generalSettings, .audioSettings, .videoSettings,
                      .accessibilitySettings, .storageSettings])
    func settingsHelpIsTheLastControl(topic: TrimatoHelp.Topic) async throws {
        let capture = AudioCaptureSession()
        defer { capture.close() }
        let content: AnyView
        switch topic {
        case .generalSettings: content = AnyView(GeneralSettingsView())
        case .audioSettings: content = AnyView(AudioRecordingSettingsView(capture: capture))
        case .videoSettings: content = AnyView(VideoSettingsView())
        case .accessibilitySettings: content = AnyView(AccessibilitySettingsView())
        case .storageSettings: content = AnyView(MediaCacheSettingsView())
        default: Issue.record("Expected a Settings topic"); return
        }
        let host = NSHostingView(rootView: SettingsHelpPage(topic: topic) { content })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 680),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        func attribute(_ item: NSObject, _ key: String) -> Any? {
            item.responds(to: NSSelectorFromString(key)) ? item.value(forKey: key) : nil
        }
        func descendants(_ item: NSObject) -> [NSObject] {
            [item] + ((attribute(item, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(descendants)
        }
        let roles = ["AXButton", "AXTextField", "AXCheckBox", "AXSlider", "AXPopUpButton", "AXRadioButton", "AXDisclosureTriangle"]
        let controls = descendants(host).filter { roles.contains(attribute($0, "accessibilityRole") as? String ?? "") }
        func isHelp(_ item: NSObject) -> Bool {
            attribute(item, "accessibilityTitle") as? String == "Help" ||
                attribute(item, "accessibilityLabel") as? String == "Help"
        }
        #expect(controls.filter(isHelp).count == 1)
        #expect(isHelp(try #require(controls.last)))
        let destination = try TrimatoHelp.destination(for: topic)
        #expect(destination.page == topic.rawValue.replacingOccurrences(of: "trimato-", with: "") + ".html")
    }

    @Test func contextualTopicIsBundledAndLinked() throws {
        let helpURL = try #require(Bundle.main.url(forResource: "Trimato", withExtension: "help"))
        let help = try #require(Bundle(url: helpURL))
        for topic in TrimatoHelp.Topic.allCases {
            let destination = try TrimatoHelp.destination(for: topic)
            #expect(help.bundleIdentifier == destination.bookIdentifier)
            #expect(destination.bookIdentifier.contains(".c"))
            #expect(FileManager.default.fileExists(atPath: destination.pageURL.path))
            let content = try String(contentsOf: destination.pageURL, encoding: .utf8)
            #expect(content.contains("<a name=\"\(topic.rawValue)\"></a>"))
        }
        let pageURL = try #require(help.url(forResource: "trim-silences", withExtension: "html"))
        let page = try String(contentsOf: pageURL, encoding: .utf8)
        #expect(page.contains("<a name=\"\(TrimatoHelp.Topic.trimSilences.rawValue)\"></a>"))
        #expect(page.contains("Warning:"))
        #expect(page.contains("jump cuts"))
        #expect(page.contains("Individual removed pauses cannot currently be restored or adjusted separately."))
        for name in ["index", "clip-editor"] {
            let url = try #require(help.url(forResource: name, withExtension: "html"))
            #expect(try String(contentsOf: url, encoding: .utf8).contains("href=\"trim-silences.html\""))
        }
        let indexURL = try #require(help.url(forResource: "Trimato", withExtension: "cshelpindex"))
        #expect(try Data(contentsOf: indexURL).count > 0)
    }
}
