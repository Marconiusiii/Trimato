import SwiftUI

struct MacEditorPane<Content: View>: View {
    let name: String
    let accessibilityFocusRequest: Int?
    private let content: Content
    @State private var handledFocusRequest = 0
    @AccessibilityFocusState private var paneFocused: Bool

    init(
        _ name: String,
        accessibilityFocusRequest: Int? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.name = name
        self.accessibilityFocusRequest = accessibilityFocusRequest
        self.content = content()
    }

    var body: some View {
        content
            .accessibilityElement(children: .contain)
            .accessibilityLabel(name)
            .accessibilityFocused($paneFocused)
            .onAppear { handleFocusRequest(accessibilityFocusRequest) }
            .onChange(of: accessibilityFocusRequest) { request in
                handleFocusRequest(request)
            }
    }

    private func handleFocusRequest(_ request: Int?) {
        guard let request, request > handledFocusRequest else { return }
        handledFocusRequest = request
        paneFocused = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            paneFocused = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            paneFocused = true
        }
    }
}
