import AppKit
import SwiftUI
@testable import Trimato

@MainActor final class FilmControlsState: ObservableObject {
    @Published var filter = ClipFilter(kind: .technicolor)
}
struct FilmControlsHost: View {
    @ObservedObject var state: FilmControlsState
    var body: some View { VStack { ClipFilterParameters(filter: $state.filter) }.padding() }
}
@main struct FilmLookControlsCheck {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited); app.finishLaunching()
        let state = FilmControlsState()
        let host = NSHostingView(rootView: FilmControlsHost(state: state).environment(\.accessibilityEnabled, true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        func settle() async throws {
            host.layoutSubtreeIfNeeded(); host.display()
            try await Task.sleep(for: .milliseconds(50))
            precondition(!window.isVisible && !window.isKeyWindow && !app.isActive)
        }
        func attribute(_ item: NSObject, _ name: String) -> Any? {
            item.responds(to: NSSelectorFromString(name)) ? item.value(forKey: name) : nil
        }
        func elements() -> [NSObject] {
            var seen = Set<ObjectIdentifier>(), found: [NSObject] = []
            func walk(_ item: NSObject) {
                guard seen.insert(ObjectIdentifier(item)).inserted else { return }
                found.append(item)
                (attribute(item, "accessibilityChildren") as? [NSObject] ?? []).forEach(walk)
            }
            walk(host); return found
        }
        for value in [0.0, -1, 2] {
            for key in ["cyanOffset", "magentaOffset", "yellowOffset"] { state.filter.values[key] = value }
            try await settle()
            let controls = elements().filter { attribute($0, "accessibilityRole") as? String == "AXPopUpButton" }
            for label in ["Cyan horizontal offset", "Magenta horizontal offset", "Yellow horizontal offset"] {
                guard let item = controls.first(where: { attribute($0, "accessibilityLabel") as? String == label || attribute($0, "accessibilityTitle") as? String == label || (attribute($0, "accessibilityTitleUIElement") as? NSObject).flatMap { attribute($0, "accessibilityValue") as? String } == label }) else {
                    for item in elements() { print("AX: \(String(describing: attribute(item,"accessibilityRole"))) \(String(describing: attribute(item,"accessibilityLabel"))) \(String(describing: attribute(item,"accessibilityValue"))) desc=\(String(describing: attribute(item,"accessibilityValueDescription"))) titleElement=\(String(describing: attribute(item,"accessibilityTitleUIElement")))") }
                    fatalError("Missing native offset control: \(label)")
                }
                let presented = attribute(item, "accessibilityValueDescription") as? String ?? attribute(item, "accessibilityValue") as? String
                precondition(presented == FilmLook.offsetDescription(value), "Offset value is not directional: \(String(describing: presented))")
            }
        }
        print("PASS: three native offset controls expose correct Cyan/Magenta/Yellow labels and Centered/left/right values; no app activation or visible window")
    }
}
