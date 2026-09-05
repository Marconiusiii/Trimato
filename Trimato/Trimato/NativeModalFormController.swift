import AppKit
import SwiftUI

/// A narrow AppKit bridge for the one behavior SwiftUI has not exposed
/// consistently in Trimato: a primary action that is also the window's real
/// native default button.
struct NativeDefaultButton: NSViewRepresentable {
    let title: String
    var isEnabled = true
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> DefaultActionButton {
        let button = DefaultActionButton(
            title: title,
            target: context.coordinator,
            action: #selector(Coordinator.invoke)
        )
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.keyEquivalent = "\r"
        button.keyEquivalentModifierMask = []
        button.isEnabled = isEnabled
        return button
    }

    func updateNSView(_ button: DefaultActionButton, context: Context) {
        context.coordinator.action = action
        button.title = title
        button.isEnabled = isEnabled
        button.installAsDefaultButton()
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func invoke() {
            action()
        }
    }
}

@MainActor
final class DefaultActionButton: NSButton {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installAsDefaultButton()
    }

    func installAsDefaultButton() {
        guard let window else { return }
        window.defaultButtonCell = cell as? NSButtonCell
    }
}

struct NativeModalActions: View {
    let primaryTitle: String
    var primaryEnabled = true
    let cancel: () -> Void
    let primary: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
            NativeDefaultButton(
                title: primaryTitle,
                isEnabled: primaryEnabled,
                action: primary
            )
        }
    }
}
