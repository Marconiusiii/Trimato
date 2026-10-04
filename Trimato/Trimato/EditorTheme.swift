import SwiftUI
import AppKit

/// Use the actual marker labels and time strings when deciding whether a row fits.
enum EditorControlLayout {
    static func markerRowWidth(inValue: String, outValue: String, textSize: InterfaceTextSize) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize * textSize.scale)
        let rows = [["Mark In", "In: \(inValue)", "Clear In"],
                    ["Mark Out", "Out: \(outValue)", "Clear Out"]]
        return rows.map { labels in
            labels.reduce(CGFloat(0)) { $0 + ($1 as NSString).size(withAttributes: [.font: font]).width }
                + 96 // Native button insets, row spacing, and group padding.
        }.max() ?? 0
    }
}

nonisolated enum EditorAccent: String, CaseIterable, Identifiable {
    case teal, blue, indigo, purple, rose, amber
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var assetName: String { "Accent" + title }

    static func saved(in defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: AppPreferenceKey.accentColor) ?? "") ?? .teal
    }
}

/// Asset colors supply light, dark, and increased-contrast variants to both UI frameworks.
enum EditorTheme {
    static let workspace = Color("Workspace")
    static let controlSurface = Color("ControlSurface")
    static let raisedSurface = Color("RaisedSurface")
    static let separator = Color("Separator")
    static func accent(for choice: EditorAccent) -> Color { Color(choice.assetName) }
    static func selection(for choice: EditorAccent) -> Color { Color(choice.assetName + "Selection") }
    static func controlAccent(for choice: EditorAccent) -> Color { Color(choice.assetName + "Fill") }
    static let secondaryText = Color("SecondaryText")
    static let playhead = Color("Playhead")
    static let dialogTitle = Font.title2.weight(.semibold)
    static let dialogPadding: CGFloat = 20
    static let actionSpacing: CGFloat = 12
}

private struct EditorAppearance: ViewModifier {
    var filledAction = false
    @AppStorage(AppPreferenceKey.accentColor) private var accent = EditorAccent.teal
    @AppStorage(AppPreferenceKey.interfaceTextSize) private var textSize = InterfaceTextSize.standard

    func body(content: Content) -> some View {
        content
            .tint(filledAction ? EditorTheme.controlAccent(for: accent) : EditorTheme.accent(for: accent))
            .controlSize(.regular)
            .font(.system(size: NSFont.preferredFont(forTextStyle: .body).pointSize * textSize.scale))
    }
}

/// Scales explicit text styles as well as the inherited body font. Each view
/// observes the preference directly, including separately hosted AppKit cells.
private struct EditorTextStyle: ViewModifier {
    @AppStorage(AppPreferenceKey.interfaceTextSize) private var textSize = InterfaceTextSize.standard
    let style: NSFont.TextStyle
    let design: Font.Design
    let weight: Font.Weight?

    func body(content: Content) -> some View {
        content.font(.system(size: NSFont.preferredFont(forTextStyle: style).pointSize * textSize.scale,
                             weight: weight ?? (style == .headline ? .semibold : .regular), design: design))
    }
}

extension View {
    func editorFont(_ style: NSFont.TextStyle = .body, design: Font.Design = .default,
                    weight: Font.Weight? = nil) -> some View {
        modifier(EditorTextStyle(style: style, design: design, weight: weight))
    }

    func editorAppearance() -> some View { modifier(EditorAppearance()) }
    func editorPrimaryAction() -> some View { modifier(EditorAppearance(filledAction: true)) }
}
