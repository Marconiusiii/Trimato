import XCTest

final class SupportTrimatoUITests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["TRIMATO_SUPPORT_AUTOMATIC_APPROVAL"] == "1" else {
            throw XCTSkip("Use the Trimato Support Tests scheme for local StoreKit UI testing.")
        }
    }
    @MainActor
    func testWelcomeAndMenuOpenSupportAndCaptureReviewScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-trimato-support-ui-tests"]
        app.launch()
        let welcome = app.windows["Trimato"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 10), app.debugDescription)
        let entry = welcome.buttons["Support Trimato…"]
        XCTAssertTrue(entry.exists, app.debugDescription)
        entry.click()
        let support = app.windows["Support Trimato"]
        XCTAssertTrue(support.waitForExistence(timeout: 5), app.debugDescription)
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
        app.menuBars.menuBarItems["Trimato"].click()
        app.menuItems["Support Trimato…"].click()
        XCTAssertTrue(support.waitForExistence(timeout: 5))
        XCTAssertTrue(support.buttons["com.marconius.trimato.support.littleSlice"].exists)
    }

    @MainActor
    func testVerifiedPurchaseReturnsToSupportWithThankYou() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-trimato-support-ui-tests"]
        app.launch()
        let entry = app.windows["Trimato"].buttons["Support Trimato…"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.click()
        let support = app.windows["Support Trimato"]
        let tip = support.buttons["com.marconius.trimato.support.littleSlice"]
        XCTAssertTrue(tip.waitForExistence(timeout: 15))
        support.buttons["com.marconius.trimato.support.littleSlice"].click()
        let thanks = support.staticTexts["trimato.support.thank-you"]
        XCTAssertTrue(thanks.waitForExistence(timeout: 15), support.debugDescription)
        XCTAssertTrue(support.buttons["com.marconius.trimato.support.littleSlice"].isEnabled)
        XCTAssertEqual(thanks.value as? String ?? thanks.label, "Thank you for supporting Trimato with A little slice.")
        let confirmation = XCTAttachment(screenshot: support.screenshot())
        confirmation.name = "TrimatoSupport-Confirmation"
        confirmation.lifetime = .keepAlways
        add(confirmation)
    }
}
