import XCTest

final class StrengthAppUITests: XCTestCase {
    func testPairReadRelaunchAndForgetAgainstTheLiveServer() throws {
        guard LiveConfig.enabled else {
            throw XCTSkip("Live server config was not generated for this run.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        // Start from a known unpaired state if a previous run left a token behind.
        if app.tabBars.buttons["Settings"].waitForExistence(timeout: 3) {
            forgetDevice(in: app)
        }

        let server = app.textFields["server-url"]
        XCTAssertTrue(server.waitForExistence(timeout: 15))
        // The Debug default already points at the local server. Rewriting a prefilled field
        // in XCUITest is fragile, so only type when it is not already the target address.
        let currentServer = server.value as? String ?? ""
        if !currentServer.contains("127.0.0.1:8000") {
            clearAndType(server, text: LiveConfig.serverURL)
        }

        let code = app.textFields["pairing-code"]
        XCTAssertTrue(code.exists)
        code.tap()
        code.typeText(LiveConfig.pairingCode)
        if app.buttons["Done"].waitForExistence(timeout: 2) {
            app.buttons["Done"].tap()
        }

        let pairButton = app.buttons["pair-button"]
        XCTAssertTrue(pairButton.waitForExistence(timeout: 5))
        pairButton.tap()

        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Readiness"].waitForExistence(timeout: 10))
        attachScreenshot(app, name: "01-today")

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 10))
        let datePredicate = NSPredicate(
            format: "label CONTAINS %@",
            LiveConfig.expectedSessionDate
        )
        XCTAssertTrue(
            app.descendants(matching: .any).matching(datePredicate)
                .firstMatch.waitForExistence(timeout: 10),
            "expected the seeded session date in History"
        )
        attachScreenshot(app, name: "02-history")

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Device id"].waitForExistence(timeout: 10))
        attachScreenshot(app, name: "03-settings")

        // Relaunch: the Keychain token must restore the paired state.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 20))
        attachScreenshot(app, name: "04-today-after-relaunch")

        forgetDevice(in: app)
        XCTAssertTrue(app.textFields["server-url"].waitForExistence(timeout: 10))
        attachScreenshot(app, name: "05-pairing-after-forget")
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func clearAndType(_ field: XCUIElement, text: String) {
        field.tap()
        if let current = field.value as? String, !current.isEmpty {
            field.typeText(
                String(repeating: XCUIKeyboardKey.delete.rawValue, count: max(current.count, 60))
            )
        }
        field.typeText(text)
    }

    private func forgetDevice(in app: XCUIApplication) {
        app.tabBars.buttons["Settings"].tap()
        let button = app.buttons["forget-device"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        let confirm = app.sheets.buttons["Forget this device"]
        if confirm.waitForExistence(timeout: 3) {
            confirm.tap()
        } else {
            let matches = app.buttons.matching(identifier: "Forget this device")
            matches.element(boundBy: matches.count - 1).tap()
        }
        XCTAssertTrue(app.textFields["server-url"].waitForExistence(timeout: 10))
    }
}
