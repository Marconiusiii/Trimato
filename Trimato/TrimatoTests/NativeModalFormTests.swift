import AppKit
import SwiftUI
import Testing
@testable import Trimato

@Suite("Native modal forms")
struct NativeModalFormTests {
    @Test @MainActor func primaryActionIsThePanelsDirectNativeDefaultButton() {
        let registration = NativeModalActionRegistration()
        let hostingController = NSHostingController(rootView: AnyView(Text("Form")))
        let controller = NativeModalPanelViewController(
            hostingController: hostingController,
            primaryTitle: "Apply",
            cancelTitle: "Cancel",
            registration: registration,
            cancel: {}
        )
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: controller.requiredContentSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = controller
        ProjectCreationWindowConfiguration.configureDefaultButton(controller.primaryButton, in: panel)

        #expect(controller.primaryButton.superview === panel.contentView)
        #expect(controller.cancelButton.superview === panel.contentView)
        #expect(panel.defaultButtonCell === controller.primaryButton.cell)
        #expect(controller.primaryButton.keyEquivalent == "\r")
        #expect(controller.cancelButton.keyEquivalent == "\u{1b}")
    }
}
