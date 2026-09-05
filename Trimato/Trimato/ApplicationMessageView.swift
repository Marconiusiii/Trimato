import Combine
import SwiftUI

nonisolated struct ApplicationMessageDescriptor: Equatable, Sendable {
    let title: String
    let message: String
}

@MainActor
final class ApplicationMessageSession: ObservableObject, Identifiable {
    let id = UUID()
    let descriptor: ApplicationMessageDescriptor
    private var dismissed: (() -> Void)?

    init(descriptor: ApplicationMessageDescriptor, dismissed: @escaping () -> Void) {
        self.descriptor = descriptor
        self.dismissed = dismissed
    }

    func finish() {
        let action = dismissed
        dismissed = nil
        action?()
    }
}

@MainActor
final class ApplicationMessageRegistry: ObservableObject {
    static let shared = ApplicationMessageRegistry()

    @Published private var sessions: [UUID: ApplicationMessageSession] = [:]

    func register(
        _ descriptor: ApplicationMessageDescriptor,
        dismissed: @escaping () -> Void
    ) -> UUID {
        let session = ApplicationMessageSession(descriptor: descriptor, dismissed: dismissed)
        sessions[session.id] = session
        return session.id
    }

    func session(id: UUID) -> ApplicationMessageSession? {
        sessions[id]
    }

    func remove(id: UUID) {
        sessions[id] = nil
    }
}

extension View {
    func applicationMessage(
        _ message: ApplicationMessageDescriptor?,
        dismissed: @escaping () -> Void
    ) -> some View {
        modifier(ApplicationMessagePresenter(message: message, dismissed: dismissed))
    }
}

private struct ApplicationMessagePresenter: ViewModifier {
    let message: ApplicationMessageDescriptor?
    let dismissed: () -> Void

    @Environment(\.openWindow) private var openWindow
    @State private var presentedMessage: ApplicationMessageDescriptor?

    func body(content: Content) -> some View {
        content.onChange(of: message, initial: true) { _, message in
            guard let message, message != presentedMessage else { return }
            presentedMessage = message
            let sessionID = ApplicationMessageRegistry.shared.register(message) {
                presentedMessage = nil
                dismissed()
            }
            openWindow(id: "application-message", value: sessionID)
        }
    }
}

struct ApplicationMessageWindowRoot: View {
    let sessionID: UUID
    @ObservedObject private var registry = ApplicationMessageRegistry.shared
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let session = registry.session(id: sessionID) {
                ApplicationMessageView(
                    descriptor: session.descriptor,
                    done: {
                        session.finish()
                        close()
                    }
                )
                .onDisappear {
                    session.finish()
                    registry.remove(id: sessionID)
                }
            } else {
                EmptyView()
            }
        }
    }

    private func close() {
        dismissWindow(id: "application-message", value: sessionID)
    }
}

private struct ApplicationMessageView: View {
    let descriptor: ApplicationMessageDescriptor
    let done: () -> Void
    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(descriptor.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)
            Text(descriptor.message)
                .textSelection(.enabled)
            HStack {
                Spacer()
                NativeDefaultButton(title: "OK", action: done)
            }
        }
        .padding(24)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            await Task.yield()
            headingFocused = true
        }
    }
}
