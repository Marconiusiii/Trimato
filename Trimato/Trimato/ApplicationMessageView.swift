import AppKit
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
final class ApplicationMessageWindowCoordinator {
    static let shared = ApplicationMessageWindowCoordinator()

    private var sessions: [UUID: ApplicationMessageSession] = [:]
    private var windows: [UUID: NativeModalWindowController] = [:]

    @discardableResult
    func present(
        _ descriptor: ApplicationMessageDescriptor,
        dismissed: @escaping () -> Void
    ) -> UUID {
        let session = ApplicationMessageSession(descriptor: descriptor, dismissed: dismissed)
        let id = session.id
        let controller = NativeModalWindowController(
            title: descriptor.title,
            contentSize: NSSize(width: 460, height: 190),
            rootView: ApplicationMessageView(
                descriptor: descriptor,
                done: { ApplicationMessageWindowCoordinator.shared.dismiss(id: id) }
            ),
            closed: { [weak self, weak session] in
                session?.finish()
                self?.sessions[id] = nil
                self?.windows[id] = nil
            }
        )
        sessions[id] = session
        windows[id] = controller
        Task { @MainActor [weak self] in
            while NSApp.modalWindow?.identifier?.rawValue == "Trimato.OperationProgress" {
                try? await Task.sleep(for: .milliseconds(50))
            }
            self?.windows[id]?.showModal()
        }
        return id
    }

    func dismiss(id: UUID) {
        windows[id]?.closeModal()
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

    @State private var presentedMessage: ApplicationMessageDescriptor?

    func body(content: Content) -> some View {
        content.onChange(of: message, initial: true) { _, message in
            guard let message, message != presentedMessage else { return }
            presentedMessage = message
            ApplicationMessageWindowCoordinator.shared.present(message) {
                presentedMessage = nil
                dismissed()
            }
        }
    }
}

struct ApplicationMessageView: View {
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
