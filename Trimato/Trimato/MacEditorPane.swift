import SwiftUI

struct MacEditorPane<Content: View>: View {
    let name: String
    private let content: Content

    init(_ name: String, @ViewBuilder content: () -> Content) {
        self.name = name
        self.content = content()
    }

    var body: some View {
        content
            .accessibilityElement(children: .contain)
            .accessibilityLabel(name)
    }
}
