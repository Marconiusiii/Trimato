//
//  TrimatoUITests.swift
//  TrimatoUITests
//
//  Created by Marco Salsiccia on 5/5/26.
//

import XCTest

final class TrimatoUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testGeneralSettingsAndCommandW() throws {
        let app = XCUIApplication()
        app.launch()
        app.typeKey(",", modifierFlags: .command)
        let generalButton = app.buttons["General"]
        let generalTab = app.radioButtons["General"]
        if generalButton.waitForExistence(timeout: 3) { generalButton.click() }
        else if generalTab.exists { generalTab.click() }
        let autoSave = app.checkBoxes["Auto-Save"]
        XCTAssertTrue(autoSave.waitForExistence(timeout: 5), app.debugDescription)
        let wasEnabled = autoSave.value as? String == "1"
        defer {
            if autoSave.exists, (autoSave.value as? String == "1") != wasEnabled {
                autoSave.click()
            }
        }
        if !wasEnabled { autoSave.click() }

        let minutes = app.textFields["Minutes between saves"]
        XCTAssertTrue(minutes.waitForExistence(timeout: 3))
        XCTAssertTrue(minutes.isEnabled)
        if !wasEnabled { autoSave.click() }
        app.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(autoSave.waitForExistence(timeout: 1))
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 2))
    }

    @MainActor
    func testIdleResourceBaseline() throws {
        let app = XCUIApplication()
        app.launch()
        Thread.sleep(forTimeInterval: 2)
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTCPUMetric(application: app), XCTMemoryMetric(application: app)],
                options: options) {
            Thread.sleep(forTimeInterval: 2)
        }
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
