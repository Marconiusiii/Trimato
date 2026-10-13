import AppKit
import ApplicationServices
import XCTest

final class SupportTrimatoUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["TRIMATO_SUPPORT_AUTOMATIC_APPROVAL"] == "1"
                || ProcessInfo.processInfo.environment["TRIMATO_SUPPORT_LOCAL_TESTING"] == "1" else {
            throw XCTSkip("Use a scheme with the local StoreKit configuration for these UI tests.")
        }
    }
    @MainActor
    func testWelcomeAndMenuOpenSupportAndCaptureReviewScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-trimato-support-ui-tests", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        let welcome = app.windows["Trimato"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 10), app.debugDescription)
        let entry = welcome.buttons["Support Trimato…"]
        XCTAssertTrue(entry.exists, app.debugDescription)
        entry.click()
        let support = app.windows["Support Trimato"]
        XCTAssertTrue(support.waitForExistence(timeout: 5), app.debugDescription)
        let headings = try supportHeadings(in: app)
        XCTAssertTrue(headings.contains("Support Trimato"), headings.description)
        XCTAssertTrue(headings.contains("Support options"), headings.description)
        XCTAssertTrue(support.staticTexts.containing(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "If Trimato helps you make the cut", "If Trimato helps you make the cut")).firstMatch.exists)
        let options = [
            ("littleSlice", "A little slice", "$0.99"),
            ("juicyCut", "A juicy cut", "$2.99"),
            ("freshTake", "A fresh take", "$4.99"),
            ("wholeTomato", "The whole tomato", "$9.99")
        ]
        for (id, name, price) in options {
            let button = support.buttons["com.marconius.trimato.support." + id]
            XCTAssertTrue(button.waitForExistence(timeout: 15), app.debugDescription)
            XCTAssertTrue(button.isEnabled)
            XCTAssertTrue(button.label.contains(name), button.label)
            XCTAssertTrue(button.label.contains(price), button.label)
        }
        // Export real window pixels without displaying them in the chat.
        let screenshot = support.screenshot()
        for (id, _, _) in options {
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "TrimatoSupport-" + id
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let welcomeAttachment = XCTAttachment(screenshot: welcome.screenshot())
        welcomeAttachment.name = "TrimatoWelcome-Support"
        welcomeAttachment.lifetime = .keepAlways
        add(welcomeAttachment)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(support.waitForNonExistence(timeout: 5), "Command+W did not close Support")
        XCTAssertTrue(welcome.exists, "Closing Support must leave the welcome window open")
        app.menuBars.menuBarItems["Trimato"].click()
        app.menuItems["Support Trimato…"].click()
        XCTAssertTrue(support.waitForExistence(timeout: 5))
        XCTAssertTrue(support.buttons["com.marconius.trimato.support.littleSlice"].exists)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(support.waitForNonExistence(timeout: 5), "Escape did not close Support")
        XCTAssertTrue(welcome.exists)
        entry.click()
        XCTAssertTrue(support.waitForExistence(timeout: 5))
        support.buttons["Close"].click()
        XCTAssertTrue(support.waitForNonExistence(timeout: 5), "Close did not close Support")
    }

    @MainActor
    func testVerifiedPurchaseReturnsToSupportWithThankYou() throws {
        guard ProcessInfo.processInfo.environment["TRIMATO_SUPPORT_AUTOMATIC_APPROVAL"] == "1" else {
            throw XCTSkip("Use Trimato Support Tests for automated purchase approval; test the payment dialog manually.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-trimato-support-ui-tests", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        let entry = app.windows["Trimato"].buttons["Support Trimato…"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.click()
        let support = app.windows["Support Trimato"]
        let option = support.buttons["com.marconius.trimato.support.littleSlice"]
        XCTAssertTrue(option.waitForExistence(timeout: 15))
        support.buttons["com.marconius.trimato.support.littleSlice"].click()
        let result = support.sheets.firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 15), "A verified purchase must present its confirmation sheet")
        let resultMessage = result.staticTexts["trimato.support.result-message"]
        XCTAssertTrue(resultMessage.exists)
        XCTAssertEqual(resultMessage.value as? String ?? resultMessage.label, "Thank you for supporting Trimato with A little slice.")
        XCTAssertTrue(result.buttons["Done"].exists)
        result.buttons["Done"].click()
        XCTAssertTrue(result.waitForNonExistence(timeout: 5))
        XCTAssertTrue(support.exists, "Done must return to Support")
        let thanks = support.staticTexts["trimato.support.thank-you"]
        XCTAssertTrue(thanks.waitForExistence(timeout: 15), support.debugDescription)
        XCTAssertTrue(support.buttons["com.marconius.trimato.support.littleSlice"].isEnabled)
        XCTAssertEqual(thanks.value as? String ?? thanks.label, "Thank you for supporting Trimato with A little slice.")
        XCTAssertTrue(try supportHeadings(in: app).contains("Thank you"))
        let confirmation = XCTAttachment(screenshot: support.screenshot())
        confirmation.name = "TrimatoSupport-Confirmation"
        confirmation.lifetime = .keepAlways
        add(confirmation)
    }

    // Read native heading roles from Trimato's Support window, not other apps.
    @MainActor
    private func supportHeadings(in app: XCUIApplication) throws -> [String] {
        func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
            return result
        }
        let running = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.marconius.trimato").first)
        let application = AXUIElementCreateApplication(running.processIdentifier)
        let windows = try XCTUnwrap(attribute(kAXWindowsAttribute, of: application) as? [AXUIElement])
        let window = try XCTUnwrap(windows.first { attribute(kAXTitleAttribute, of: $0) as? String == "Support Trimato" })
        func collect(_ element: AXUIElement, depth: Int) -> [String] {
            guard depth < 30 else { return [] }
            var texts: [String] = []
            if attribute(kAXRoleAttribute, of: element) as? String == kAXHeadingRole {
                for key in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                    if let text = attribute(key, of: element) as? String { texts.append(text) }
                }
            }
            for child in attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? [] {
                texts += collect(child, depth: depth + 1)
            }
            return texts
        }
        return collect(window, depth: 0)
    }
}
