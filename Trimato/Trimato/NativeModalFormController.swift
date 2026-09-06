import AppKit
import Combine
import SwiftUI

@MainActor
final class NativeModalFocusRequest: ObservableObject {
    @Published private(set) var revision = 0

    func request() {
        revision += 1
    }
}

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
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(windowStateChanged),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(windowStateChanged),
            name: NSWindow.didUpdateNotification,
            object: window
        )
        installAsDefaultButton()
    }

    func installAsDefaultButton() {
        guard let window else { return }
        guard window.defaultButtonCell !== cell else { return }
        window.defaultButtonCell = cell as? NSButtonCell
        window.enableKeyEquivalentForDefaultButtonCell()
    }

    @objc private func windowStateChanged() {
        installAsDefaultButton()
    }
}

/// Owns a real standalone AppKit modal window while allowing each feature to
/// supply standard SwiftUI content. The window is deliberately excluded from
/// the Window menu and remains the only interactive Trimato window until its
/// owning feature closes it.
@MainActor
final class NativeModalWindowController: NSWindowController, NSWindowDelegate {
    private var didClose = false
    private var closeRequested = false
    private var windowIsClosing = false
    private var modalSession: NSApplication.ModalSession?
    private var modalSessionTimer: Timer?
    private let focusRequest: NativeModalFocusRequest?
    private weak var returnWindow: NSWindow?
    private let returned: () -> Void
    private let closed: () -> Void

    init<Content: View>(
        title: String,
        contentSize: NSSize,
        resizable: Bool = false,
        closable: Bool = true,
        identifier: NSUserInterfaceItemIdentifier? = nil,
        rootView: Content,
        focusRequest: NativeModalFocusRequest? = nil,
        returnWindow: NSWindow? = nil,
        returned: @escaping () -> Void = {},
        closed: @escaping () -> Void
    ) {
        self.focusRequest = focusRequest
        self.returnWindow = returnWindow
        self.returned = returned
        self.closed = closed
        let hostingController = NSHostingController(rootView: rootView)
        var styleMask: NSWindow.StyleMask = [.titled]
        if closable { styleMask.insert(.closable) }
        if resizable { styleMask.insert(.resizable) }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.identifier = identifier
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior.insert(.transient)
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showModal() {
        guard let window, modalSession == nil else { return }
        modalSession = NSApp.beginModalSession(for: window)
        let timer = Timer(
            timeInterval: 1.0 / 30.0,
            target: self,
            selector: #selector(advanceModalSession),
            userInfo: nil,
            repeats: true
        )
        modalSessionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func closeModal() {
        guard modalSession != nil else {
            closeWindowAndFinish()
            return
        }
        closeRequested = true
    }

    func windowWillClose(_ notification: Notification) {
        guard modalSession != nil else {
            finishOnce()
            return
        }
        windowIsClosing = true
        closeRequested = true
    }

    func windowDidBecomeKey(_ notification: Notification) {
        focusRequest?.request()
    }

    @objc private func advanceModalSession() {
        guard let modalSession else { return }
        if closeRequested {
            NSApp.abortModal()
            endModalSession(modalSession)
            return
        }

        let response = NSApp.runModalSession(modalSession)
        if closeRequested {
            NSApp.abortModal()
            endModalSession(modalSession)
        } else if response != .continue {
            endModalSession(modalSession)
        }
    }

    private func endModalSession(_ modalSession: NSApplication.ModalSession) {
        modalSessionTimer?.invalidate()
        modalSessionTimer = nil
        NSApp.endModalSession(modalSession)
        self.modalSession = nil
        closeWindowAndFinish()
    }

    private func closeWindowAndFinish() {
        if !windowIsClosing {
            window?.orderOut(nil)
            window?.close()
        }
        finishOnce()
    }

    private func finishOnce() {
        guard !didClose else { return }
        didClose = true
        closed()
        restoreReturnWindow()
    }

    private func restoreReturnWindow() {
        guard let returnWindow else {
            returned()
            return
        }
        let returned = returned
        returnWindow.makeKeyAndOrderFront(nil)
        Task { @MainActor [weak returnWindow] in
            for _ in 0..<20 {
                guard let returnWindow else {
                    returned()
                    return
                }
                if returnWindow.isKeyWindow {
                    await Task.yield()
                    returned()
                    return
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            returned()
        }
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
