import AppKit
import Combine
import SwiftUI
import Testing
@testable import Trimato

@Suite(.serialized)
@MainActor
struct GeneratorAccessibilityTests {
    private final class Values: ObservableObject {
        @Published var definition: GeneratorDefinition = {
            var value = GeneratorDefinition()
            value.kind = .text
            value.textSettings.text = "Example title"
            return value
        }()
    }

    private struct Controls: View {
        @ObservedObject var values: Values
        @State private var duration = 5.0

        var body: some View {
            Form {
                TextGeneratorControls(definition: $values.definition)
                TextField("Duration in Seconds", value: $duration, format: .number)
            }.padding().frame(width: 600)
        }
    }

    // These checks cover native roles, relationships, and values only.
    // They do not prove VoiceOver navigation order, speech, or menu dismissal behavior.
    private func attribute(_ element: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue()
    }

    private func elements(in root: NSObject) -> [NSObject] {
        let children = attribute(root, "accessibilityChildren") as? [NSObject] ?? []
        return [root] + children.flatMap { elements(in: $0) }
    }

    @Test func nativeFormExposesControlsAndDisclosureValues() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let values = Values()
        let host = NSHostingView(rootView: Controls(values: values))
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))

        func control(_ role: String, _ title: String) throws -> NSObject {
            let label = try #require(elements(in: host).first {
                attribute($0, "accessibilityRole") as? String == "AXStaticText"
                    && attribute($0, "accessibilityValue") as? String == title
            })
            // SwiftUI exports the reverse title relationship even when the native AppKit
            // popup/text view does not expose it through its own in-process getter.
            let targets = try #require(attribute(label, "accessibilityServesAsTitleForUIElements") as? [NSObject])
            #expect(targets.count == 1, "The visible label must belong to one control")
            let target = try #require(targets.first)
            return try #require(elements(in: target).first {
                attribute($0, "accessibilityRole") as? String == role
            }, "Missing native \(role) associated with visible label \(title)")
        }

        let template = try control("AXPopUpButton", "Template")
        #expect(attribute(template, "accessibilityValue") as? String == TextTemplate.centerTitle.title)
        let text = try control("AXTextArea", TextTemplate.centerTitle.textLabel)
        #expect(attribute(text, "accessibilityValue") as? String == "Example title")
        let duration = try control("AXTextField", "Duration in Seconds")
        #expect(attribute(duration, "accessibilityValue") as? String == "5")


        func disclosure(_ title: String) throws -> NSObject {
            try #require(elements(in: host).first {
                attribute($0, "accessibilityRole") as? String == "AXDisclosureTriangle"
                    && attribute($0, "accessibilityLabel") as? String == title
            })
        }
        func toggle(_ disclosure: NSObject) throws {
            let press = NSSelectorFromString("accessibilityPerformPress")
            try #require(disclosure.responds(to: press))
            let action = unsafeBitCast(disclosure.method(for: press),
                                      to: (@convention(c) (AnyObject, Selector) -> Bool).self)
            #expect(action(disclosure, press))
        }
        let groups: [(String, [String], [String])] = [
            ("Typography", ["Font", "Weight", "Text Alignment"],
             ["Font Size in Pixels", "Additional Line Spacing in Pixels"]),
            ("Appearance", ["Text Color", "Full-frame Background", "Outline Color", "Panel Color"],
             ["Text Color Hexadecimal", "Outline Color Hexadecimal", "Panel Color Hexadecimal", "Panel Opacity in Percent"]),
            ("Layout", ["Screen Position"],
             ["Safe Margin in Percent", "Maximum Width as Percent of Safe Area",
              "Horizontal Offset as Percent of Frame Width", "Vertical Offset as Percent of Frame Height"])
        ]
        values.definition.textSettings.outlineEnabled = true
        values.definition.textSettings.panelEnabled = true
        values.definition.textSettings.color.choice = .custom
        values.definition.textSettings.outlineColor.choice = .custom
        values.definition.textSettings.panelColor.choice = .custom
        for (title, pickers, fields) in groups {
            #expect((attribute(try disclosure(title), "accessibilityValue") as? NSNumber)?.intValue == 0)
            try toggle(disclosure(title))
            try await Task.sleep(for: .milliseconds(200))
            #expect((attribute(try disclosure(title), "accessibilityValue") as? NSNumber)?.intValue == 1)
            for picker in pickers { _ = try control("AXPopUpButton", picker) }
            for field in fields { _ = try control("AXTextField", field) }
            try toggle(disclosure(title))
            try await Task.sleep(for: .milliseconds(200))
            #expect((attribute(try disclosure(title), "accessibilityValue") as? NSNumber)?.intValue == 0)
        }

        values.definition.textSettings.apply(.titleAndSubtitle)
        values.definition.textSettings.secondaryText = "Supporting text"
        try await Task.sleep(for: .milliseconds(200))
        _ = try control("AXTextArea", TextTemplate.titleAndSubtitle.textLabel)
        let secondary = try control("AXTextArea", TextTemplate.titleAndSubtitle.secondaryLabel)
        #expect(attribute(secondary, "accessibilityValue") as? String == "Supporting text")
        let retainedTemplate = try control("AXPopUpButton", "Template")
        #expect(retainedTemplate === template, "Changing parameters must preserve the native picker instance")

    }

    @Test func pixelEditingPreservesSavedStyleAndIndependentSpacing() {
        var value = GeneratorDefinition()
        value.height = 1080
        #expect(abs(value.textFontSizePixels - 64.8) < 0.0001)
        #expect(abs(value.textLineSpacingPixels - 9.72) < 0.0001)
        value.textLineSpacingPixels = 12
        value.textFontSizePixels = 72
        #expect(abs(value.textLineSpacingPixels - 12) < 0.0001)
        #expect(abs(value.textFontSizePixels - 72) < 0.0001)
        #expect(value.textTypographyError == nil)
        value.textLineSpacingPixels = -1
        #expect(value.textTypographyError?.contains("pixels") == true)
        value.textFontSizePixels = 0
        #expect(value.textTypographyError?.contains("Font Size") == true)
    }
}
