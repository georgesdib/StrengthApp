import XCTest

@testable import StrengthApp

@MainActor
final class WorkoutAutomationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var opener: StubShortcutOpener!
    private var automation: WorkoutAutomation!
    private var suite = ""

    override func setUp() {
        super.setUp()
        // A per-test suite: XCTest can run test methods concurrently, and a shared domain would let
        // one test clear another's shortcuts mid-flight.
        suite = "com.georgesdibpersonalteam.StrengthApp.tests.automation.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        opener = StubShortcutOpener()
        automation = WorkoutAutomation(defaults: defaults, opener: opener)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testFiresOncePerSessionAndEvent() async {
        automation.startShortcut = "Gym lights"

        let first = await automation.handle(.started, sessionID: "w1")
        let second = await automation.handle(.started, sessionID: "w1")
        XCTAssertTrue(first)
        XCTAssertFalse(second)

        XCTAssertEqual(opener.urls.count, 1)
        XCTAssertEqual(opener.urls.first?.query, "name=Gym%20lights")
    }

    func testStartAndEndAreSeparateChannels() async {
        automation.startShortcut = "Lights on"
        automation.endShortcut = "Lights off"

        let start = await automation.handle(.started, sessionID: "w1")
        let end = await automation.handle(.ended, sessionID: "w1")
        XCTAssertTrue(start)
        XCTAssertTrue(end)

        XCTAssertEqual(opener.urls.count, 2)
        XCTAssertEqual(opener.urls.map(\.query), ["name=Lights%20on", "name=Lights%20off"])
    }

    func testEmptyNameIsOff() async {
        automation.startShortcut = "   "

        let fired = await automation.handle(.started, sessionID: "w1")
        XCTAssertFalse(fired)
        XCTAssertTrue(opener.urls.isEmpty)
    }

    func testDifferentSessionsBothFire() async {
        automation.startShortcut = "Gym lights"

        let first = await automation.handle(.started, sessionID: "w1")
        let second = await automation.handle(.started, sessionID: "w2")
        XCTAssertTrue(first)
        XCTAssertTrue(second)

        XCTAssertEqual(opener.urls.count, 2)
    }

    func testRefusedOpenKeepsTheWorkoutUnaffectedAndAllowsRetry() async {
        automation.startShortcut = "Gym lights"
        opener.result = false

        let refused = await automation.handle(.started, sessionID: "w1")
        XCTAssertFalse(refused)
        // A refused URL is not remembered, so a later transition can try again.
        opener.result = true
        let retried = await automation.handle(.started, sessionID: "w1")
        XCTAssertTrue(retried)
        XCTAssertEqual(opener.urls.count, 2)
    }

    func testURLShape() {
        let url = WorkoutAutomation.url(forShortcutNamed: "Lights & fan")
        XCTAssertEqual(url?.scheme, "shortcuts")
        XCTAssertEqual(url?.host, "run-shortcut")
        XCTAssertEqual(url?.query, "name=Lights%20%26%20fan")
    }
}

private final class StubShortcutOpener: ShortcutURLOpening {
    var urls: [URL] = []
    var result = true

    func open(_ url: URL) async -> Bool {
        urls.append(url)
        return result
    }
}
