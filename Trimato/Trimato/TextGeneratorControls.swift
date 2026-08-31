import SwiftUI

struct TextGeneratorControls: View {
    @Binding var definition: GeneratorDefinition
    // This view owns its native pickers and their restoration state.
    @AccessibilityFocusState private var pickerFocus: String?
    @State private var fitReport: String?
    @State private var styleExpanded = false
    @State private var appearanceExpanded = false
    @State private var layoutExpanded = false

    private var settings: Binding<TextGeneratorSettings> { $definition.textSettings }

    var body: some View {
        GroupBox("Text") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Template", selection: restoring(Binding(
                    get: { definition.textSettings.template },
                    set: { definition.textSettings.apply($0) }
                ), "template")) {
                    ForEach(TextTemplate.allCases) { Text($0.title).tag($0) }
                }.accessibilityFocused($pickerFocus, equals: "template")
                textArea(definition.textSettings.template.textLabel, text: settings.text)
                if definition.textSettings.template.hasSecondaryText {
                    textArea(definition.textSettings.template.secondaryLabel, text: settings.secondaryText)
                }
                DisclosureGroup("Typography", isExpanded: $styleExpanded) {
                    VStack(alignment: .leading) {
                        Picker("Font", selection: restoring(settings.font, "font")) {
                            ForEach(TextFontFamily.allCases) { Text($0.title).tag($0) }
                        }.accessibilityFocused($pickerFocus, equals: "font")
                        Picker("Weight", selection: restoring(settings.weight, "weight")) {
                            ForEach(TextFontWeight.allCases) { Text($0.title).tag($0) }
                        }.accessibilityFocused($pickerFocus, equals: "weight")
                        numberField("Text Size as Percent of Frame Height", value: settings.sizePercent)
                        Picker("Text Alignment", selection: restoring(settings.alignment, "alignment")) {
                            ForEach(TextAlignmentChoice.allCases) { Text($0.title).tag($0) }
                        }.accessibilityFocused($pickerFocus, equals: "alignment")
                        numberField("Line Spacing as Percent of Text Size", value: settings.lineSpacing)
                    }
                }
                DisclosureGroup("Appearance", isExpanded: $appearanceExpanded) {
                    VStack(alignment: .leading) {
                        colorPicker("Text Color", color: settings.color, key: "textColor")
                        Picker("Full-frame Background", selection: restoring(settings.background, "background")) {
                            ForEach(TextBackground.allCases) { Text($0.title).tag($0) }
                        }.accessibilityFocused($pickerFocus, equals: "background")
                        Toggle("Outline", isOn: settings.outlineEnabled)
                        if definition.textSettings.outlineEnabled {
                            colorPicker("Outline Color", color: settings.outlineColor, key: "outlineColor")
                        }
                        Toggle("Shadow", isOn: settings.shadowEnabled)
                        Toggle("Text Backing Panel", isOn: settings.panelEnabled)
                        if definition.textSettings.panelEnabled {
                            colorPicker("Panel Color", color: settings.panelColor, key: "panelColor")
                            numberField("Panel Opacity in Percent", value: settings.panelOpacity)
                        }
                    }
                }
                DisclosureGroup("Layout", isExpanded: $layoutExpanded) {
                    VStack(alignment: .leading) {
                        Picker("Screen Position", selection: restoring(settings.position, "position")) {
                            ForEach(TextPosition.allCases) { Text($0.title).tag($0) }
                        }.accessibilityFocused($pickerFocus, equals: "position")
                        numberField("Safe Margin in Percent", value: settings.safeMargin)
                        numberField("Maximum Width as Percent of Safe Area", value: settings.maximumWidth)
                        numberField("Horizontal Offset as Percent of Frame Width", value: settings.horizontalOffset)
                        numberField("Vertical Offset as Percent of Frame Height", value: settings.verticalOffset)
                        Text("Positive offsets move text right or down. Text size and margins scale with the video frame.")
                    }
                }
                HStack {
                    Button("Check Text Fit") {
                        do { fitReport = try TextGeneratorRenderer.layout(definition).report }
                        catch { fitReport = error.localizedDescription }
                    }
                    Button("Reset Style") { definition.textSettings.apply(definition.textSettings.template) }
                }
            }
        }
        // Keep the window usable without introducing an accessibility scroll-area wrapper.
        // Only one detailed settings group needs to be open at a time.
        .onChange(of: styleExpanded) { _, open in if open { appearanceExpanded = false; layoutExpanded = false } }
        .onChange(of: appearanceExpanded) { _, open in if open { styleExpanded = false; layoutExpanded = false } }
        .onChange(of: layoutExpanded) { _, open in if open { styleExpanded = false; appearanceExpanded = false } }
        .alert("Text Fit", isPresented: Binding(get: { fitReport != nil }, set: { if !$0 { fitReport = nil } })) {
            Button("OK") { fitReport = nil }
        } message: { Text(fitReport ?? "") }
    }

    private func textArea(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading) {
            Text(label)
            TextEditor(text: text)
                .frame(height: 64)
                .border(.separator)
        }
        .accessibilityElement(children: .combine)
    }

    private func numberField(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
            TextField("", value: value, format: .number)
                .frame(maxWidth: 110)
        }.accessibilityElement(children: .combine)
    }

    private func colorPicker(_ label: String, color: Binding<TextGeneratorColor>, key: String) -> some View {
        VStack(alignment: .leading) {
            Picker(label, selection: restoring(color.choice, key)) {
                ForEach(TextColorChoice.allCases) { Text($0.title).tag($0) }
            }.accessibilityFocused($pickerFocus, equals: key)
            if color.wrappedValue.choice == .custom {
                HStack {
                    Text("\(label) Hexadecimal")
                    TextField("", text: color.customHex)
                }.accessibilityElement(children: .combine)
            }
        }
    }

    private func restoring<T>(_ binding: Binding<T>, _ key: String) -> Binding<T> {
        Binding(get: { binding.wrappedValue }, set: { value in
            binding.wrappedValue = value
            pickerFocus = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { pickerFocus = key }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { pickerFocus = key }
        })
    }
}
