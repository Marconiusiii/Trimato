import AppKit
import Foundation
import Darwin
@testable import Trimato

/// Resolves bundled colors only. Does not create an application, window, or view.
@main struct EditorAppearanceCheck {
    static func verify(_ value: Bool, _ message: String) {
        guard value else { print("FAIL: \(message)"); exit(1) }
    }

    @MainActor static func main() {
        verify(NSApp == nil, "Check must not launch an application")
        guard let bundle = Bundle(path: CommandLine.arguments[1]),
              let defaults = UserDefaults(suiteName: "trimato-appearance-check-\(UUID())") else { exit(1) }
        verify(EditorAccent.saved(in: defaults) == .teal, "Missing preference must use Teal")
        defaults.setVolatileDomain([AppPreferenceKey.accentColor: "unknown"], forName: UserDefaults.argumentDomain)
        verify(EditorAccent.saved(in: defaults) == .teal, "Unknown preference must use Teal")
        var minimumText = Double.infinity
        var minimumSelection = Double.infinity
        var minimumFill = Double.infinity
        let appearances: [NSAppearance.Name] = [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]
        for choice in EditorAccent.allCases {
            defaults.setVolatileDomain([AppPreferenceKey.accentColor: choice.rawValue], forName: UserDefaults.argumentDomain)
            verify(EditorAccent.saved(in: defaults) == choice, "Saved choice did not round-trip")
            for name in appearances {
                guard let appearance = NSAppearance(named: name) else { exit(1) }
                appearance.performAsCurrentDrawingAppearance {
                    func color(_ name: String) -> NSColor {
                        guard let color = NSColor(named: name, bundle: bundle)?.usingColorSpace(.sRGB) else {
                            print("FAIL: missing bundled color \(name)"); exit(1)
                        }
                        return color
                    }
                    let accent = color(choice.assetName)
                    for surface in ["Workspace", "ControlSurface", "RaisedSurface"] {
                        let ratio = contrast(accent, color(surface))
                        minimumText = min(minimumText, ratio)
                        verify(ratio >= 7, "\(choice.title) on \(surface) in \(name.rawValue): \(ratio)")
                        verify(contrast(color("SecondaryText"), color(surface)) >= 7, "Secondary text contrast")
                    }
                    let selection = contrast(accent, color(choice.assetName + "Selection"))
                    minimumSelection = min(minimumSelection, selection)
                    verify(selection >= 3, "Selection outline contrast")
                    let fill = contrast(NSColor.white, color(choice.assetName + "Fill"))
                    minimumFill = min(minimumFill, fill)
                    verify(fill >= 7, "White text against filled-button palette")
                }
            }
        }
        verify(NSApp == nil, "Check created an application")
        print(String(format: "PASS: six saved accents, fallback, and 24 bundled appearance variants. Minimum ratios: accent text %.2f:1, selection outlines %.2f:1, white on button fill %.2f:1. Secondary text passes 7:1.", minimumText, minimumSelection, minimumFill))
    }

    static func luminance(_ color: NSColor) -> Double {
        let c = color.usingColorSpace(.sRGB)!
        func linear(_ x: CGFloat) -> Double {
            let v = Double(x)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return linear(c.redComponent) * 0.2126 + linear(c.greenComponent) * 0.7152 + linear(c.blueComponent) * 0.0722
    }

    static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let first = luminance(a), second = luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}
