import SwiftUI

struct TextGeneratorControls: View {
    @Binding var definition: GeneratorDefinition
    @AccessibilityFocusState private var focusedPicker: PickerFocus?
    @State private var expandedSection: Section?
    @State private var fitReport: String?

    private enum Section { case typography, appearance, layout }
    private enum PickerFocus: Hashable {
        case template, font, weight, alignment, textColor, background, outlineColor, panelColor, position
    }

    private var settings: Binding<TextGeneratorSettings> { $definition.textSettings }

    var body: some View {
        Group {
            Picker("Template", selection: pickerBinding(Binding(
                get: { definition.textSettings.template },
                set: { definition.textSettings.apply($0) }
            ), focus: .template)) {
                ForEach(TextTemplate.allCases) { template in
                    Text(template.title).tag(template)
                }
            }
            .pickerStyle(.menu)
            .accessibilityFocused($focusedPicker, equals: .template)

            LabeledContent(definition.textSettings.template.textLabel) {
                TextEditor(text: settings.text)
                    .frame(height: 80)
            }
            if definition.textSettings.template.hasSecondaryText {
                LabeledContent(definition.textSettings.template.secondaryLabel) {
                    TextEditor(text: settings.secondaryText)
                        .frame(height: 64)
                }
            }

            DisclosureGroup("Typography", isExpanded: expanded(.typography)) {
                typographyControls
            }
            DisclosureGroup("Appearance", isExpanded: expanded(.appearance)) {
                appearanceControls
            }
            DisclosureGroup("Layout", isExpanded: expanded(.layout)) {
                layoutControls
            }
            Button("Check Text Fit") {
                do { fitReport = try TextGeneratorRenderer.layout(definition).report }
                catch { fitReport = error.localizedDescription }
            }
            Button("Reset Style") {
                definition.textSettings.apply(definition.textSettings.template)
            }
        }
        .alert("Text Fit", isPresented: Binding(
            get: { fitReport != nil },
            set: { if !$0 { fitReport = nil } }
        )) {
            Button("OK") { fitReport = nil }
        } message: {
            Text(fitReport ?? "")
        }
    }

    private var typographyControls: some View {
        Group {
            Picker("Font", selection: pickerBinding(settings.font, focus: .font)) {
                ForEach(TextFontFamily.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityFocused($focusedPicker, equals: .font)
            Picker("Weight", selection: pickerBinding(settings.weight, focus: .weight)) {
                ForEach(TextFontWeight.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityFocused($focusedPicker, equals: .weight)
            TextField("Font Size in Pixels", value: $definition.textFontSizePixels,
                      format: .number.precision(.fractionLength(0...2)))
            Picker("Text Alignment", selection: pickerBinding(settings.alignment, focus: .alignment)) {
                ForEach(TextAlignmentChoice.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityFocused($focusedPicker, equals: .alignment)
            TextField("Additional Line Spacing in Pixels", value: $definition.textLineSpacingPixels,
                      format: .number.precision(.fractionLength(0...2)))
                .help("Extra space between lines. Zero adds no extra space.")
        }
    }

    private var appearanceControls: some View {
        Group {
            colorControls("Text Color", color: settings.color, focus: .textColor)
            Picker("Full-frame Background", selection: pickerBinding(settings.background, focus: .background)) {
                ForEach(TextBackground.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityFocused($focusedPicker, equals: .background)
            Toggle("Outline", isOn: settings.outlineEnabled)
            if definition.textSettings.outlineEnabled {
                colorControls("Outline Color", color: settings.outlineColor, focus: .outlineColor)
            }
            Toggle("Shadow", isOn: settings.shadowEnabled)
            Toggle("Text Backing Panel", isOn: settings.panelEnabled)
            if definition.textSettings.panelEnabled {
                colorControls("Panel Color", color: settings.panelColor, focus: .panelColor)
                TextField("Panel Opacity in Percent", value: settings.panelOpacity,
                          format: .number.precision(.fractionLength(0...2)))
            }
        }
    }

    private var layoutControls: some View {
        Group {
            Picker("Screen Position", selection: pickerBinding(settings.position, focus: .position)) {
                ForEach(TextPosition.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityFocused($focusedPicker, equals: .position)
            TextField("Safe Margin in Percent", value: settings.safeMargin,
                      format: .number.precision(.fractionLength(0...2)))
                .help("Keeps text away from the edges of the video.")
            TextField("Maximum Width as Percent of Safe Area", value: settings.maximumWidth,
                      format: .number.precision(.fractionLength(0...2)))
            TextField("Horizontal Offset as Percent of Frame Width", value: settings.horizontalOffset,
                      format: .number.precision(.fractionLength(0...2)))
                .help("Positive values move text right; negative values move it left.")
            TextField("Vertical Offset as Percent of Frame Height", value: settings.verticalOffset,
                      format: .number.precision(.fractionLength(0...2)))
                .help("Positive values move text down; negative values move it up.")
        }
    }

    @ViewBuilder
    private func colorControls(_ title: String, color: Binding<TextGeneratorColor>, focus: PickerFocus) -> some View {
        Picker(title, selection: pickerBinding(color.choice, focus: focus)) {
            ForEach(TextColorChoice.allCases) { Text($0.title).tag($0) }
        }
        .accessibilityFocused($focusedPicker, equals: focus)
        if color.wrappedValue.choice == .custom {
            TextField("\(title) Hexadecimal", text: color.customHex)
                .help("Enter a six-digit hexadecimal color, such as FFFFFF for white.")
        }
    }

    private func expanded(_ section: Section) -> Binding<Bool> {
        Binding(get: { expandedSection == section }, set: { isExpanded in
            if isExpanded { expandedSection = section }
            else if expandedSection == section { expandedSection = nil }
        })
    }

    private func pickerBinding<Value>(_ binding: Binding<Value>, focus: PickerFocus) -> Binding<Value> {
        Binding(get: { binding.wrappedValue }, set: { value, transaction in
            // Forward the native control's update context through this binding adapter.
            withTransaction(transaction) {
                binding.transaction(transaction).wrappedValue = value
            }
            focusedPicker = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { focusedPicker = focus }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { focusedPicker = focus }
        })
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
