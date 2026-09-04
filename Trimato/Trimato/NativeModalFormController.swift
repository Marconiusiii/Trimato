import AppKit
import Combine
import SwiftUI

@MainActor
final class NativeModalActionRegistration: ObservableObject {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    private(set) var isEnabled = false
    private var actionOwner: UUID?
    private var action: (() -> Void)?
    private var enabledObserverOwner: UUID?
    private var enabledObserver: ((Bool) -> Void)?

    func configure(owner: UUID, enabled: Bool, action: @escaping () -> Void) {
        actionOwner = owner
        self.action = action
        setEnabled(enabled)
    }

    func clear(owner: UUID) {
        guard actionOwner == owner else { return }
        actionOwner = nil
        action = nil
        setEnabled(false)
    }

    func observeEnabled(owner: UUID, _ observer: @escaping (Bool) -> Void) {
        enabledObserverOwner = owner
        enabledObserver = observer
        observer(isEnabled)
    }

    func stopObservingEnabled(owner: UUID) {
        guard enabledObserverOwner == owner else { return }
        enabledObserverOwner = nil
        enabledObserver = nil
    }

    func invoke() {
        guard isEnabled else { return }
        action?()
    }

    func reset() {
        actionOwner = nil
        action = nil
        setEnabled(false)
    }

    private func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        enabledObserver?(enabled)
    }
}

private struct NativeModalPrimaryActionBridge: NSViewRepresentable {
    let registration: NativeModalActionRegistration
    let enabled: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityElement(false)
        context.coordinator.registration = registration
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        registration.configure(owner: context.coordinator.id, enabled: enabled, action: action)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.registration?.clear(owner: coordinator.id)
    }

    final class Coordinator {
        let id = UUID()
        weak var registration: NativeModalActionRegistration?

        init() {}
    }
}

extension View {
    func nativeModalPrimaryAction(
        _ registration: NativeModalActionRegistration,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        background(NativeModalPrimaryActionBridge(
            registration: registration,
            enabled: enabled,
            action: action
        ))
    }

    @ViewBuilder
    func nativeModalPrimaryAction(
        _ registration: NativeModalActionRegistration?,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        if let registration {
            nativeModalPrimaryAction(registration, enabled: enabled, action: action)
        } else {
            self
        }
    }
}

struct NativeModalSheetPresenter<Content: View>: NSViewRepresentable {
    let isPresented: Bool
    let title: String
    let primaryTitle: String
    let cancelTitle: String
    let registration: NativeModalActionRegistration
    let cancel: () -> Void
    let dismissed: () -> Void
    let content: Content

    init(
        isPresented: Bool,
        title: String,
        primaryTitle: String,
        cancelTitle: String = "Cancel",
        registration: NativeModalActionRegistration,
        cancel: @escaping () -> Void,
        dismissed: @escaping () -> Void = {},
        @ViewBuilder content: () -> Content
    ) {
        self.isPresented = isPresented
        self.title = title
        self.primaryTitle = primaryTitle
        self.cancelTitle = cancelTitle
        self.registration = registration
        self.cancel = cancel
        self.dismissed = dismissed
        self.content = content()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.owner = context.coordinator
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: Anchor, context: Context) {
        context.coordinator.update(
            isPresented: isPresented,
            title: title,
            primaryTitle: primaryTitle,
            cancelTitle: cancelTitle,
            registration: registration,
            cancel: cancel,
            dismissed: dismissed,
            content: AnyView(content),
            parent: view.window
        )
    }

    static func dismantleNSView(_ view: Anchor, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    final class Anchor: NSView {
        weak var owner: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            owner?.attach(to: window)
        }
    }

    @MainActor
    final class Coordinator {
        private weak var parent: NSWindow?
        private var panel: NSPanel?
        private var panelController: NativeModalPanelViewController?
        private var isPresented = false
        private var title = ""
        private var primaryTitle = ""
        private var cancelTitle = "Cancel"
        private var registration: NativeModalActionRegistration?
        private var cancel: (() -> Void)?
        private var dismissed: (() -> Void)?
        private var pendingDismissed: (() -> Void)?
        private var content: AnyView?
        private var sheetObserver: NSObjectProtocol?

        func attach(to parent: NSWindow?) {
            self.parent = parent
            presentIfPossible()
        }

        func update(
            isPresented: Bool,
            title: String,
            primaryTitle: String,
            cancelTitle: String,
            registration: NativeModalActionRegistration,
            cancel: @escaping () -> Void,
            dismissed: @escaping () -> Void,
            content: AnyView,
            parent: NSWindow?
        ) {
            self.isPresented = isPresented
            self.title = title
            self.primaryTitle = primaryTitle
            self.cancelTitle = cancelTitle
            self.registration = registration
            self.cancel = cancel
            self.dismissed = dismissed
            self.content = content
            attach(to: parent)
            if !isPresented { closePanel(notify: true) }
        }

        private func presentIfPossible() {
            guard isPresented, panel == nil, let parent, parent.attachedSheet == nil,
                  let registration, let content else { return }
            registration.reset()
            let hostingController = NSHostingController(rootView: content)
            let panelController = NativeModalPanelViewController(
                hostingController: hostingController,
                primaryTitle: primaryTitle,
                cancelTitle: cancelTitle,
                registration: registration,
                cancel: { [weak self] in self?.cancel?() }
            )
            panelController.loadViewIfNeeded()
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: panelController.requiredContentSize),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            panel.title = title
            panel.contentViewController = panelController
            panel.isReleasedWhenClosed = false
            panel.setAccessibilityModal(true)
            self.panelController = panelController
            self.panel = panel
            sheetObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didEndSheetNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.configureDefaultButton() }
            }
            parent.beginSheet(panel) { [weak self] _ in
                guard let self else { return }
                let pendingDismissed = self.pendingDismissed
                self.pendingDismissed = nil
                pendingDismissed?()
            }
            configureDefaultButton()
        }

        private func configureDefaultButton() {
            guard let panel, let panelController, panel.attachedSheet == nil else { return }
            ProjectCreationWindowConfiguration.configureDefaultButton(
                panelController.primaryButton,
                in: panel
            )
        }

        private func closePanel(notify: Bool) {
            guard let panel else { return }
            pendingDismissed = notify ? dismissed : nil
            if let sheetObserver {
                NotificationCenter.default.removeObserver(sheetObserver)
                self.sheetObserver = nil
            }
            panel.sheetParent?.endSheet(panel)
            panel.orderOut(nil)
            self.panel = nil
            panelController?.disconnect()
            panelController = nil
            registration?.reset()
        }

        func invalidate() {
            isPresented = false
            closePanel(notify: false)
            parent = nil
            content = nil
            cancel = nil
            dismissed = nil
            pendingDismissed = nil
        }
    }
}

@MainActor
final class NativeModalPanelViewController: NSViewController {
    let primaryButton: NSButton
    let cancelButton: NSButton
    private let hostingController: NSHostingController<AnyView>
    private let registration: NativeModalActionRegistration
    private let cancel: () -> Void
    private let enabledObservationID = UUID()
    private(set) var requiredContentSize = NSSize(width: 480, height: 240)

    init(
        hostingController: NSHostingController<AnyView>,
        primaryTitle: String,
        cancelTitle: String,
        registration: NativeModalActionRegistration,
        cancel: @escaping () -> Void
    ) {
        self.hostingController = hostingController
        self.registration = registration
        self.cancel = cancel
        primaryButton = NSButton(title: primaryTitle, target: nil, action: nil)
        cancelButton = NSButton(title: cancelTitle, target: nil, action: nil)
        super.init(nibName: nil, bundle: nil)
        addChild(hostingController)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let formView = hostingController.view
        formView.layoutSubtreeIfNeeded()
        let fittingSize = formView.fittingSize
        let width = max(fittingSize.width, 360)
        let height = max(fittingSize.height + 76, 180)
        let rootView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        primaryButton.bezelStyle = .rounded
        primaryButton.setButtonType(.momentaryPushIn)
        primaryButton.keyEquivalent = "\r"
        primaryButton.keyEquivalentModifierMask = []
        primaryButton.target = self
        primaryButton.action = #selector(primaryPressed)

        cancelButton.bezelStyle = .rounded
        cancelButton.setButtonType(.momentaryPushIn)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)

        formView.translatesAutoresizingMaskIntoConstraints = false
        primaryButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(formView)
        rootView.addSubview(cancelButton)
        rootView.addSubview(primaryButton)
        NSLayoutConstraint.activate([
            formView.topAnchor.constraint(equalTo: rootView.topAnchor),
            formView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            formView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            formView.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -16),
            cancelButton.trailingAnchor.constraint(equalTo: primaryButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: primaryButton.centerYAnchor),
            primaryButton.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
            primaryButton.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -24),
        ])
        requiredContentSize = NSSize(width: width, height: height)
        view = rootView
        registration.observeEnabled(owner: enabledObservationID) { [weak self] enabled in
            self?.primaryButton.isEnabled = enabled
        }
    }

    func disconnect() {
        registration.stopObservingEnabled(owner: enabledObservationID)
    }

    @objc private func primaryPressed() {
        registration.invoke()
    }

    @objc private func cancelPressed() {
        cancel()
    }
}
