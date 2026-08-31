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
                GeneratorControlRow("Template") {
                    Picker("", selection: restoring(Binding(
                        get: { definition.textSettings.template },
                        set: { definition.textSettings.apply($0) }
                    ), "template")) {
                        ForEach(TextTemplate.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().accessibilityFocused($pickerFocus, equals: "template")
                }
                textArea(definition.textSettings.template.textLabel, text: settings.text)
                if definition.textSettings.template.hasSecondaryText {
                    textArea(definition.textSettings.template.secondaryLabel, text: settings.secondaryText)
                }
                DisclosureGroup("Typography", isExpanded: $styleExpanded) {
                    VStack(alignment: .leading) {
                        GeneratorControlRow("Font") {
                            Picker("", selection: restoring(settings.font, "font")) {
                                ForEach(TextFontFamily.allCases) { Text($0.title).tag($0) }
                            }.labelsHidden().accessibilityFocused($pickerFocus, equals: "font")
                        }
                        GeneratorControlRow("Weight") {
                            Picker("", selection: restoring(settings.weight, "weight")) {
                                ForEach(TextFontWeight.allCases) { Text($0.title).tag($0) }
                            }.labelsHidden().accessibilityFocused($pickerFocus, equals: "weight")
                        }
                        numberField("Font Size in Pixels", value: $definition.textFontSizePixels)
                        GeneratorControlRow("Text Alignment") {
                            Picker("", selection: restoring(settings.alignment, "alignment")) {
                                ForEach(TextAlignmentChoice.allCases) { Text($0.title).tag($0) }
                            }.labelsHidden().accessibilityFocused($pickerFocus, equals: "alignment")
                        }
                        numberField("Additional Line Spacing in Pixels", value: $definition.textLineSpacingPixels)
                    }
                }
                DisclosureGroup("Appearance", isExpanded: $appearanceExpanded) {
                    VStack(alignment: .leading) {
                        colorPicker("Text Color", color: settings.color, key: "textColor")
                        GeneratorControlRow("Full-frame Background") {
                            Picker("", selection: restoring(settings.background, "background")) {
                                ForEach(TextBackground.allCases) { Text($0.title).tag($0) }
                            }.labelsHidden().accessibilityFocused($pickerFocus, equals: "background")
                        }
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
                        GeneratorControlRow("Screen Position") {
                            Picker("", selection: restoring(settings.position, "position")) {
                                ForEach(TextPosition.allCases) { Text($0.title).tag($0) }
                            }.labelsHidden().accessibilityFocused($pickerFocus, equals: "position")
                        }
                        numberField("Safe Margin in Percent", value: settings.safeMargin)
                        numberField("Maximum Width as Percent of Safe Area", value: settings.maximumWidth)
                        numberField("Horizontal Offset as Percent of Frame Width", value: settings.horizontalOffset)
                        numberField("Vertical Offset as Percent of Frame Height", value: settings.verticalOffset)
                        Text("Positive offsets move text right or down. Safe margins keep text away from the edges of the video.")
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
        // Keep the detailed controls within the window without another scrolling container.
        .onChange(of: styleExpanded) { _, open in if open { appearanceExpanded = false; layoutExpanded = false } }
        .onChange(of: appearanceExpanded) { _, open in if open { styleExpanded = false; layoutExpanded = false } }
        .onChange(of: layoutExpanded) { _, open in if open { styleExpanded = false; appearanceExpanded = false } }
        .alert("Text Fit", isPresented: Binding(get: { fitReport != nil }, set: { if !$0 { fitReport = nil } })) {
            Button("OK") { fitReport = nil }
        } message: { Text(fitReport ?? "") }
    }

    private func textArea(_ label: String, text: Binding<String>) -> some View {
        GeneratorTextArea(label: label, text: text)
    }

    private func numberField(_ label: String, value: Binding<Double>) -> some View {
        GeneratorControlRow(label) {
            TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                .frame(maxWidth: 110)
        }
    }

    private func colorPicker(_ label: String, color: Binding<TextGeneratorColor>, key: String) -> some View {
        VStack(alignment: .leading) {
            GeneratorControlRow(label) {
                Picker("", selection: restoring(color.choice, key)) {
                    ForEach(TextColorChoice.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().accessibilityFocused($pickerFocus, equals: key)
            }
            if color.wrappedValue.choice == .custom {
                GeneratorControlRow("\(label) Hexadecimal") {
                    TextField("", text: color.customHex)
                }
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


private struct GeneratorTextArea: View {
    let label: String
    @Binding var text: String
    @Namespace private var labelPair

    var body: some View {
        VStack(alignment: .leading) {
            Text(label)
                .accessibilityLabeledPair(role: .label, id: "text", in: labelPair)
            TextEditor(text: $text)
                .frame(height: 64)
                .border(.separator)
                .accessibilityLabeledPair(role: .content, id: "text", in: labelPair)
        }
    }
}

// The editor uses video pixels; existing projects keep their resolution-independent style.
extension GeneratorDefinition {
    var textFontSizePixels: Double {
        get { Double(height) * textSettings.sizePercent / 100 }
        set {
            let spacing = textLineSpacingPixels
            textSettings.sizePercent = newValue / Double(height) * 100
            if newValue > 0, newValue.isFinite { textLineSpacingPixels = spacing }
        }
    }

    var textLineSpacingPixels: Double {
        get { textFontSizePixels * textSettings.lineSpacing / 100 }
        set { textSettings.lineSpacing = newValue / textFontSizePixels * 100 }
    }

    var textTypographyError: String? {
        guard height > 0 else { return nil } // Definition validation reports invalid video dimensions.
        let minimum = Double(height) / 100
        let maximum = Double(height) / 4
        if !textFontSizePixels.isFinite || !(minimum...maximum).contains(textFontSizePixels) {
            return "Font Size must be between \(minimum.formatted()) and \(maximum.formatted()) pixels for this video."
        }
        if !textLineSpacingPixels.isFinite || !(0...textFontSizePixels).contains(textLineSpacingPixels) {
            return "Additional Line Spacing must be between 0 and \(textFontSizePixels.formatted()) pixels."
        }
        return nil
    }
}
