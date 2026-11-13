import XCTest

final class StrengthAppUITests: XCTestCase {
    func testPairReadRelaunchAndForgetAgainstTheLiveServer() throws {
        guard LiveConfig.enabled else {
            throw XCTSkip("Live server config was not generated for this run.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        configureLaunch(app)
        app.launch()

        // Start from a known unpaired state if a previous run left a token behind.
        if app.tabBars.buttons["Settings"].waitForExistence(timeout: 3) {
            forgetDevice(in: app)
        }

        let server = app.textFields["server-url"]
        XCTAssertTrue(server.waitForExistence(timeout: 15))
        // The Debug default points at the local server on the default port. Rewriting a
        // prefilled field in XCUITest is fragile, so only type when it differs from the
        // configured address; an exact match means a different port is a different server.
        let currentServer = server.value as? String ?? ""
        if currentServer != LiveConfig.serverURL {
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
        let deviceID = app.staticTexts["Device id"]
        for _ in 0..<8 {
            if deviceID.exists && deviceID.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(deviceID.waitForExistence(timeout: 10))
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

    func testPhase2ReadinessPrescriptionWorkoutAndProgressAgainstTheLiveServer() throws {
        guard LiveConfig.enabled else {
            throw XCTSkip("Live server config was not generated for this run.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        configureLaunch(app)
        app.launch()

        if app.tabBars.buttons["Settings"].waitForExistence(timeout: 3) {
            forgetDevice(in: app)
        }

        let server = app.textFields["server-url"]
        XCTAssertTrue(server.waitForExistence(timeout: 15))
        let currentServer = server.value as? String ?? ""
        if currentServer != LiveConfig.serverURL {
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

        let readiness = app.buttons["log-readiness"]
        XCTAssertTrue(readiness.waitForExistence(timeout: 10))
        readiness.tap()
        XCTAssertTrue(app.navigationBars["Log readiness"].waitForExistence(timeout: 10))
        for (identifier, value) in [
            ("readiness-sleep", "4"),
            ("readiness-energy", "4"),
            ("readiness-mood", "4"),
            ("readiness-soreness", "4"),
            ("readiness-stress", "4"),
        ] {
            let field = app.textFields[identifier]
            XCTAssertTrue(field.waitForExistence(timeout: 5), identifier)
            field.tap()
            field.typeText(value)
        }
        if app.buttons["Done"].waitForExistence(timeout: 2) {
            app.buttons["Done"].tap()
        }
        let saveReadiness = app.buttons["save-readiness"]
        scrollTo(saveReadiness, in: app)
        saveReadiness.tap()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 20))

        let start = app.buttons["start-workout"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        // R7: the request opens the workout-settings sheet first; the preview appears once the
        // server has built the plan, which is fast here because the resolver is off.
        if app.navigationBars["Request workout"].waitForExistence(timeout: 10) {
            app.buttons["request-workout"].tap()
        }
        XCTAssertTrue(app.staticTexts["Workout ready"].waitForExistence(timeout: 60))
        attachScreenshot(app, name: "10-workout-ready")
        let review = app.buttons["review-workout"]
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        review.tap()
        XCTAssertTrue(app.navigationBars["Review workout"].waitForExistence(timeout: 10))
        let readyStart = app.buttons["preview-start"]
        XCTAssertTrue(readyStart.waitForExistence(timeout: 10))
        readyStart.tap()
        XCTAssertTrue(app.navigationBars["Workout"].waitForExistence(timeout: 25))
        attachScreenshot(app, name: "11-workout")

        // R8: the authenticated catalogue feeds the add-exercise picker; the server applies
        // its own 3x8-12 @ RIR 2 defaults because the phone sends only the exercise id.
        let addPlan = app.buttons["add-plan-exercise"]
        XCTAssertTrue(addPlan.waitForExistence(timeout: 10))
        addPlan.tap()
        XCTAssertTrue(app.navigationBars["Add exercise"].waitForExistence(timeout: 10))
        let exerciseSearch = app.searchFields.firstMatch
        XCTAssertTrue(exerciseSearch.waitForExistence(timeout: 5))
        exerciseSearch.tap()
        exerciseSearch.typeText("lat pulldown")
        let latPulldown = app.buttons["exercise-option-lat_pulldown"]
        XCTAssertTrue(latPulldown.waitForExistence(timeout: 10))
        latPulldown.tap()
        let latLabel = app.staticTexts["Lat Pulldown"]
        scrollTo(latLabel, in: app)
        XCTAssertTrue(latLabel.waitForExistence(timeout: 10))
        attachScreenshot(app, name: "11b-plan-exercise-added")

        // Exercise-centric logging: open the first planned exercise and complete planned set 1.
        let openExercise = app.descendants(matching: .any)["open-exercise-0"]
        for _ in 0..<8 {
            if openExercise.exists && openExercise.isHittable { break }
            app.swipeDown()
        }
        XCTAssertTrue(openExercise.waitForExistence(timeout: 10))
        openExercise.tap()
        let plannedDone = app.buttons["log-planned-set-1"]
        XCTAssertTrue(plannedDone.waitForExistence(timeout: 10))
        plannedDone.tap()

        let reps = app.textFields["set-reps"]
        scrollTo(reps, in: app)
        XCTAssertTrue(reps.waitForExistence(timeout: 10))
        // The sheet is prepopulated from the plan. Keep those values; this test only adds
        // the optional velocity and verifies that the completed set reaches the log.
        let velocity = app.textFields["set-velocity"]
        clearAndType(velocity, text: "0.62")
        if app.keyboards.buttons["Done"].waitForExistence(timeout: 2) {
            app.keyboards.buttons["Done"].tap()
        } else if app.toolbars.buttons["Done"].waitForExistence(timeout: 2) {
            app.toolbars.buttons["Done"].tap()
        }
        let saveSet = app.buttons["save-set"]
        scrollTo(saveSet, in: app)
        saveSet.tap()
        let loggedVelocity = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "0.62 m/s")
        ).firstMatch
        for _ in 0..<5 {
            if loggedVelocity.exists { break }
            app.swipeDown()
        }
        XCTAssertTrue(loggedVelocity.waitForExistence(timeout: 5))
        attachScreenshot(app, name: "12-set-logged")

        // Force-quit after the acknowledged set and recover the active workout through Today.
        app.terminate()
        app.launch()
        let resume = app.buttons["resume-workout"]
        XCTAssertTrue(resume.waitForExistence(timeout: 25))
        resume.tap()
        XCTAssertTrue(app.navigationBars["Workout"].waitForExistence(timeout: 15))
        let recoveredVelocity = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "0.62 m/s")
        ).firstMatch
        for _ in 0..<4 {
            if recoveredVelocity.exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(recoveredVelocity.waitForExistence(timeout: 10))
        attachScreenshot(app, name: "12b-workout-recovered")

        let finish = app.buttons["finish-workout"]
        scrollTo(finish, in: app)
        finish.tap()
        XCTAssertTrue(
            app.navigationBars["Session report"].waitForExistence(timeout: 20),
            "an acknowledged completion opens the report before returning to Today"
        )
        let reportDone = app.buttons["report-done"]
        XCTAssertTrue(reportDone.waitForExistence(timeout: 10))
        reportDone.tap()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 20))

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 10))
        let reportDatePredicate = NSPredicate(
            format: "label CONTAINS %@", LiveConfig.expectedSessionDate
        )
        let completedSession = app.descendants(matching: .any)
            .matching(reportDatePredicate).firstMatch
        XCTAssertTrue(completedSession.waitForExistence(timeout: 10))
        completedSession.tap()
        XCTAssertTrue(app.navigationBars["Workout"].waitForExistence(timeout: 10))
        let historyReport = app.buttons["history-view-report"]
        scrollTo(historyReport, in: app)
        XCTAssertTrue(historyReport.waitForExistence(timeout: 10))
        historyReport.tap()
        XCTAssertTrue(app.navigationBars["Session report"].waitForExistence(timeout: 20))
        app.buttons["report-done"].tap()
        XCTAssertTrue(app.navigationBars["Workout"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["History"].tap()

        app.tabBars.buttons["Settings"].tap()
        let exerciseLibrary = app.descendants(matching: .any)["exercise-library-link"]
        XCTAssertTrue(exerciseLibrary.waitForExistence(timeout: 10))
        exerciseLibrary.tap()
        XCTAssertTrue(app.navigationBars["Exercise Library"].waitForExistence(timeout: 10))
        let squatRow = app.descendants(matching: .any)["exercise-library-competition_squat"]
        scrollTo(squatRow, in: app)
        XCTAssertTrue(squatRow.waitForExistence(timeout: 10))
        squatRow.tap()
        XCTAssertTrue(app.navigationBars["Competition Squat"].waitForExistence(timeout: 10))
        let latestE1RM = app.descendants(matching: .any)["exercise-e1rm-latest"]
        for _ in 0..<8 {
            if latestE1RM.exists { break }
            app.swipeUp()
        }
        // A clean throwaway database has no previous competition-squat history, so the
        // library can legitimately show "No e1RM data available". The detail screen itself
        // is still the contract under test; a seeded database exercises the latest row.
        if !latestE1RM.waitForExistence(timeout: 3) {
            let empty = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", "Eligible observations, 0")
            ).firstMatch
            XCTAssertTrue(
                empty.waitForExistence(timeout: 5),
                "expected either an e1RM observation or the explicit empty observation state"
            )
        }
        for _ in 0..<5 {
            if app.descendants(matching: .any)["exercise-history-header"].exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(
            app.descendants(matching: .any)["exercise-history-header"]
                .waitForExistence(timeout: 10)
        )
        app.navigationBars.buttons["Exercise Library"].tap()

        app.tabBars.buttons["Progress"].tap()
        XCTAssertTrue(app.navigationBars["Progress"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Coverage"].waitForExistence(timeout: 15))
        attachScreenshot(app, name: "13-progress")
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists && element.isHittable {
                return
            }
            app.swipeUp()
        }
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func configureLaunch(_ app: XCUIApplication) {
        // Argument-domain defaults override the previous app container so a live run cannot
        // accidentally pair against the real default server after a forget/relaunch.
        app.launchArguments = [
            "-ios.serverURL", LiveConfig.serverURL,
            "-ios.server.homeURL", LiveConfig.serverURL,
        ]
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
        // The button is below the server and exercise-library sections on a 6.3-inch phone;
        // waitForExistence does not scroll a lazy SwiftUI List.
        for _ in 0..<8 {
            if button.exists && button.isHittable { break }
            app.swipeUp()
        }
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
