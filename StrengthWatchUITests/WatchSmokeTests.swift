import XCTest

/// Phase 6.7 simulator smoke test for the watch app: fetch → start → log → finish.
///
/// This runs against a disposable server seeded by scripts/watch-smoke.sh, which passes the
/// credential through TEST_RUNNER_ environment variables. Contract §17 asks for the simulator
/// path; §18 says watch UI tests are not a CI gate, so this runs on demand.
final class WatchSmokeTests: XCTestCase {
    func testFetchStartLogAndFinish() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["WATCH_SMOKE_URL"],
              let token = environment["WATCH_SMOKE_TOKEN"],
              let device = environment["WATCH_SMOKE_DEVICE"] else {
            throw XCTSkip("Run through scripts/watch-smoke.sh to seed the server and credential.")
        }

        let app = XCUIApplication()
        app.launchArguments += [
            "-watchSmokeServerURL", url,
            "-watchSmokeToken", token,
            "-watchSmokeDeviceID", device,
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        addUIInterruptionMonitor(withDescription: "Health authorisation") { alert in
            for label in ["Allow", "OK", "Allow All"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }

        // Fetch: today's watch plan arrives from the server.
        let start = app.buttons["watch-start"]
        if !start.waitForExistence(timeout: 90) {
            print("SMOKE-TREE-START:\n\(app.debugDescription)")
            XCTFail("the plan did not load on the watch")
            return
        }
        let ready = expectation(for: NSPredicate(format: "enabled == true AND label == %@", "Start on Apple Watch"),
                                evaluatedWith: start)
        wait(for: [ready], timeout: 90)
        start.tap()

        // Start one set on the first exercise.
        let exercise = app.buttons["watch-exercise-0"]
        XCTAssertTrue(exercise.waitForExistence(timeout: 30))
        sleep(1)   // let the list settle after the phase change
        let startSet = app.buttons["watch-start-set"]
        print("SMOKE-ROW hittable=\(exercise.isHittable) frame=\(exercise.frame)")
        exercise.staticTexts.firstMatch.tap()
        if !startSet.waitForExistence(timeout: 10) {
            exercise.press(forDuration: 0.1)
        }
        if !startSet.waitForExistence(timeout: 10) {
            print("SMOKE-TREE-SELECT:\n\(app.debugDescription)")
            XCTFail("the exercise did not open")
        }
        startSet.tap()
        app.tap()   // lets the interruption monitor fire

        // Log it: end the set and record RIR 5.
        let endSet = app.buttons["watch-end-set"]
        XCTAssertTrue(endSet.waitForExistence(timeout: 15))
        endSet.tap()
        // watchOS focuses the sheet's first text field, so the keyboard covers the RIR buttons.
        sleep(1)
        if app.buttons["Done"].exists {
            app.buttons["Done"].tap()
            sleep(1)
        }
        let rir = app.buttons["5"]
        XCTAssertTrue(rir.waitForExistence(timeout: 15))
        rir.tap()
        sleep(1)
        if app.buttons["Done"].exists {
            app.buttons["Done"].tap()
        }

        // Finish from the session sheet.
        let session = app.buttons["watch-session"]
        XCTAssertTrue(session.waitForExistence(timeout: 15))
        session.tap()
        let openFinish = app.buttons["watch-open-finish"]
        XCTAssertTrue(openFinish.waitForExistence(timeout: 15))
        openFinish.tap()
        let finish = app.buttons["watch-finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 15))
        finish.tap()

        // The server acknowledges the finish and the summary offers Done.
        let done = app.buttons["watch-done"]
        if !done.waitForExistence(timeout: 120) {
            print("SMOKE-TREE-FINISH:\n\(app.debugDescription)")
            XCTFail("the finish never reached the server")
        }
        done.tap()
        XCTAssertTrue(app.buttons["watch-start"].waitForExistence(timeout: 30))
    }
}
