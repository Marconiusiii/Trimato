import AppKit
import Combine
import SwiftUI

nonisolated enum ApplicationMessageInitialFocus: Equatable, Sendable {
    case button
    case message
}

nonisolated struct ApplicationMessageDescriptor: Equatable, Sendable {
    let title: String
    let message: String
    var initialFocus = ApplicationMessageInitialFocus.button
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
        sessions[id] = session
        Task { @MainActor [weak self] in
            while NSApp.modalWindow?.identifier?.rawValue == "Trimato.OperationProgress" {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let self, self.sessions[id] != nil else { return }
            let focusRequest = NativeModalFocusRequest()
            let returnWindow = NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow
            let controller = NativeModalWindowController(
                title: descriptor.title,
                contentSize: NSSize(width: 460, height: 190),
                rootView: ApplicationMessageView(
                    descriptor: descriptor,
                    focusRequest: focusRequest,
                    done: { ApplicationMessageWindowCoordinator.shared.dismiss(id: id) }
                ),
                focusRequest: focusRequest,
                returnWindow: returnWindow,
                closed: { [weak self, weak session] in
                    session?.finish()
                    self?.sessions[id] = nil
                    self?.windows[id] = nil
                }
            )
            self.windows[id] = controller
            controller.showModal()
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
    @ObservedObject var focusRequest: NativeModalFocusRequest
    let done: () -> Void
    @AccessibilityFocusState private var okFocused: Bool
    @AccessibilityFocusState private var messageFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(descriptor.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(descriptor.message)
                .textSelection(.enabled)
                .accessibilityFocused($messageFocused)
            HStack {
                Spacer()
                NativeDefaultButton(title: "OK", action: done)
                    .accessibilityFocused($okFocused)
            }
        }
        .padding(24)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: focusRequest.revision) { _, revision in
            guard revision > 0 else { return }
            Task { @MainActor in
                await Task.yield()
                if descriptor.initialFocus == .message {
                    messageFocused = true
                } else {
                    okFocused = true
                }
            }
        }
    }
}
