import XCTest

@testable import StrengthApp
@testable import StrengthCore

@MainActor
final class WorkoutAutomationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var opener: StubShortcutOpener!
    private var automation: WorkoutAutomation!
    private var sceneRunner: StubSceneRunner!
    private var suite = ""

    override func setUp() {
        super.setUp()
        // A per-test suite: XCTest can run test methods concurrently, and a shared domain would let
        // one test clear another's shortcuts mid-flight.
        suite = "com.georgesdibpersonalteam.StrengthApp.tests.automation.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        opener = StubShortcutOpener()
        sceneRunner = StubSceneRunner()
        automation = WorkoutAutomation(defaults: defaults, opener: opener, sceneRunner: sceneRunner)
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

    func testSceneRunsBeforeTheShortcut() async {
        let scene = SceneSelection(homeID: "h1", sceneID: "s1", label: "Home — Gym")
        automation.startScene = scene
        automation.startShortcut = "Gym lights"

        let ran = await automation.handle(.started, sessionID: "w1")

        XCTAssertTrue(ran)
        XCTAssertEqual(sceneRunner.ran.map(\.sceneID), ["s1"])
        XCTAssertEqual(opener.urls.count, 1)
        XCTAssertEqual(automation.startScene?.label, "Home — Gym")
    }

    func testSceneFiresOncePerEvent() async {
        automation.startScene = SceneSelection(homeID: "h1", sceneID: "s1", label: "Home — Gym")

        let first = await automation.handle(.started, sessionID: "w1")
        let second = await automation.handle(.started, sessionID: "w1")

        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertEqual(sceneRunner.ran.count, 1)
    }

    func testRefusedSceneIsRetried() async {
        automation.startScene = SceneSelection(homeID: "h1", sceneID: "s1", label: "Home — Gym")
        sceneRunner.result = false

        let refused = await automation.handle(.started, sessionID: "w1")
        XCTAssertFalse(refused)
        sceneRunner.result = true
        let retried = await automation.handle(.started, sessionID: "w1")
        XCTAssertTrue(retried)
        XCTAssertEqual(sceneRunner.ran.count, 2)
    }

    func testSceneSelectionRoundTripsThroughJSON() {
        let scene = SceneSelection(homeID: "h1", sceneID: "s1", label: "Home — Gym")
        XCTAssertEqual(SceneSelection.decode(scene.jsonString), scene)
        XCTAssertNil(SceneSelection.decode(nil))
        XCTAssertNil(SceneSelection.decode("not json"))
    }

    func testURLShape() {
        let url = WorkoutAutomation.url(forShortcutNamed: "Lights & fan")
        XCTAssertEqual(url?.scheme, "shortcuts")
        XCTAssertEqual(url?.host, "run-shortcut")
        XCTAssertEqual(url?.query, "name=Lights%20%26%20fan")
    }


    @MainActor
    func testHomesWaitersWakeEveryCallerAndAllowEarlyLoad() async {
        let waiters = HomesWaiters()
        async let first: Void = waiters.wait()
        async let second: Void = waiters.wait()
        await Task.yield()
        waiters.markLoaded()
        _ = await (first, second)
        XCTAssertTrue(waiters.loaded)

        let alreadyLoaded = HomesWaiters()
        alreadyLoaded.markLoaded()
        await alreadyLoaded.wait()
        XCTAssertTrue(alreadyLoaded.loaded)
    }
}

@MainActor
private final class StubSceneRunner: SceneRunning {
    var ran: [SceneSelection] = []
    var result = true

    func scenes() async -> [SceneSelection] { [] }

    func run(_ selection: SceneSelection) async -> Bool {
        ran.append(selection)
        return result
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
