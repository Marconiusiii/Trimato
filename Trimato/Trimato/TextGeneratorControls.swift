import SwiftUI

struct TextGeneratorControls: View {
    @Binding var definition: GeneratorDefinition
    @State private var expandedSection: Section?
    @State private var fitReport: String?

    private enum Section { case typography, appearance, layout }

    private var settings: Binding<TextGeneratorSettings> { $definition.textSettings }

    var body: some View {
        Group {
            Picker("Template", selection: Binding(
                get: { definition.textSettings.template },
                set: { definition.textSettings.apply($0) }
            )) {
                ForEach(TextTemplate.allCases) { template in
                    Text(template.title).tag(template)
                }
            }
            .pickerStyle(.menu)

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
            if let fitReport {
                LabeledContent("Text Fit") {
                    Text(fitReport)
                        .textSelection(.enabled)
                }
                Button("Dismiss Text Fit") { self.fitReport = nil }
            }
            Button("Reset Style") {
                definition.textSettings.apply(definition.textSettings.template)
            }
        }
    }

    private var typographyControls: some View {
        Group {
            Picker("Font", selection: settings.font) {
                ForEach(TextFontFamily.allCases) { Text($0.title).tag($0) }
            }

            Picker("Weight", selection: settings.weight) {
                ForEach(TextFontWeight.allCases) { Text($0.title).tag($0) }
            }

            TextField("Font Size in Points", value: $definition.textFontSizePoints,
                      format: .number.precision(.fractionLength(0...2)))
            Picker("Text Alignment", selection: settings.alignment) {
                ForEach(TextAlignmentChoice.allCases) { Text($0.title).tag($0) }
            }

            TextField("Additional Line Spacing in Points", value: $definition.textLineSpacingPoints,
                      format: .number.precision(.fractionLength(0...2)))
                .help("Extra space between lines. Zero adds no extra space.")
        }
    }

    private var appearanceControls: some View {
        Group {
            colorControls("Text Color", color: settings.color)
            Picker("Full-frame Background", selection: settings.background) {
                ForEach(TextBackground.allCases) { Text($0.title).tag($0) }
            }

            Toggle("Outline", isOn: settings.outlineEnabled)
            if definition.textSettings.outlineEnabled {
                colorControls("Outline Color", color: settings.outlineColor)
            }
            Toggle("Shadow", isOn: settings.shadowEnabled)
            Toggle("Text Backing Panel", isOn: settings.panelEnabled)
            if definition.textSettings.panelEnabled {
                colorControls("Panel Color", color: settings.panelColor)
                TextField("Panel Opacity in Percent", value: settings.panelOpacity,
                          format: .number.precision(.fractionLength(0...2)))
            }
        }
    }

    private var layoutControls: some View {
        Group {
            Picker("Screen Position", selection: settings.position) {
                ForEach(TextPosition.allCases) { Text($0.title).tag($0) }
            }

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
    private func colorControls(_ title: String, color: Binding<TextGeneratorColor>) -> some View {
        Picker(title, selection: color.choice) {
            ForEach(TextColorChoice.allCases) { Text($0.title).tag($0) }
        }

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
}

// Text is edited on a resolution-independent 1080-point canvas. The saved percentage
// keeps existing projects visually consistent when they render at another resolution.
nonisolated extension GeneratorDefinition {
    static let textTypographyReferenceHeight = 1080.0

    var textFontSizePoints: Double {
        get { Self.textTypographyReferenceHeight * textSettings.sizePercent / 100 }
        set {
            let spacing = textLineSpacingPoints
            textSettings.sizePercent = newValue / Self.textTypographyReferenceHeight * 100
            if newValue > 0, newValue.isFinite { textLineSpacingPoints = spacing }
        }
    }

    var textLineSpacingPoints: Double {
        get { textFontSizePoints * textSettings.lineSpacing / 100 }
        set { textSettings.lineSpacing = newValue / textFontSizePoints * 100 }
    }

    var textTypographyError: String? {
        guard height > 0 else { return nil } // Definition validation reports invalid video dimensions.
        let minimum = Self.textTypographyReferenceHeight / 100
        let maximum = Self.textTypographyReferenceHeight / 4
        if !textFontSizePoints.isFinite || !(minimum...maximum).contains(textFontSizePoints) {
            return "Font Size must be between \(minimum.formatted()) and \(maximum.formatted()) points."
        }
        if !textLineSpacingPoints.isFinite || !(0...textFontSizePoints).contains(textLineSpacingPoints) {
            return "Additional Line Spacing must be between 0 and \(textFontSizePoints.formatted()) points."
        }
        return nil
    }
}
