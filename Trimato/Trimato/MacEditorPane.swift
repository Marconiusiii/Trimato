import SwiftUI

struct MacEditorPane<Content: View>: View {
    private let content: Content

    init(_ _: String, @ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
    }
}
