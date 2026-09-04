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

    @Test @MainActor func nativePrimaryButtonInvokesTheCurrentActionOnce() {
        let registration = NativeModalActionRegistration()
        let owner = UUID()
        var invocationCount = 0
        registration.configure(owner: owner, enabled: true) { invocationCount += 1 }
        let controller = NativeModalPanelViewController(
            hostingController: NSHostingController(rootView: AnyView(Text("Form"))),
            primaryTitle: "Apply",
            cancelTitle: "Cancel",
            registration: registration,
            cancel: {}
        )
        controller.loadViewIfNeeded()

        controller.primaryButton.performClick(nil)

        #expect(invocationCount == 1)
    }

    @Test @MainActor func resetDisablesTheButtonWithoutInvokingItsAction() {
        let registration = NativeModalActionRegistration()
        let owner = UUID()
        var invocationCount = 0
        registration.configure(owner: owner, enabled: true) { invocationCount += 1 }
        let controller = NativeModalPanelViewController(
            hostingController: NSHostingController(rootView: AnyView(Text("Form"))),
            primaryTitle: "Apply",
            cancelTitle: "Cancel",
            registration: registration,
            cancel: {}
        )
        controller.loadViewIfNeeded()

        registration.reset()
        controller.primaryButton.performClick(nil)

        #expect(!controller.primaryButton.isEnabled)
        #expect(invocationCount == 0)
    }
}
