import SwiftUI

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

    func body(content: Content) -> some View {
        content
            .tint(filledAction ? EditorTheme.controlAccent(for: accent) : EditorTheme.accent(for: accent))
            .controlSize(.regular)
    }
}

extension View {
    func editorAppearance() -> some View { modifier(EditorAppearance()) }
    func editorPrimaryAction() -> some View { modifier(EditorAppearance(filledAction: true)) }
}
