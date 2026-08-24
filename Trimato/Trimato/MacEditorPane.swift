import AppKit
import SwiftUI

struct MacEditorPane<Content: View>: NSViewRepresentable {
    let name: String
    private let content: Content

    init(_ name: String, @ViewBuilder content: () -> Content) {
        self.name = name
        self.content = content()
    }

    func makeNSView(context: Context) -> AccessiblePaneView<Content> {
        AccessiblePaneView(name: name, rootView: content)
    }

    func updateNSView(_ nsView: AccessiblePaneView<Content>, context: Context) {
        nsView.paneName = name
        nsView.hostingView.rootView = content
    }
}

final class AccessiblePaneView<Content: View>: NSView {
    let hostingView: NSHostingView<Content>

    var paneName: String {
        didSet { setAccessibilityLabel(paneName) }
    }

    init(name: String, rootView: Content) {
        paneName = name
        hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(name)

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
