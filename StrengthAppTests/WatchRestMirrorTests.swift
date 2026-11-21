import XCTest

@testable import StrengthApp
@testable import StrengthCore

@MainActor
final class WatchRestMirrorTests: XCTestCase {
    // MARK: - Payload

    func testSnapshotRoundTripsThroughTheUserInfoMessage() throws {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = WatchRestSnapshot(
            launchId: "L1",
            sequence: 3,
            sessionId: "S1",
            endsAt: end,
            exerciseLabel: "Bench Press",
            workoutId: "W1"
        )

        let message = try XCTUnwrap(snapshot.message)
        XCTAssertEqual(message["kind"] as? String, WatchRestSnapshot.kind)
        XCTAssertEqual(WatchRestSnapshot.decode(message), snapshot)
    }

    func testNoRestEndDateSurvivesTheRoundTrip() throws {
        let snapshot = WatchRestSnapshot(
            launchId: "L1", sequence: 4, sessionId: "S1", endsAt: nil
        )
        let message = try XCTUnwrap(snapshot.message)
        let decoded = try XCTUnwrap(WatchRestSnapshot.decode(message))
        XCTAssertNil(decoded.endsAt)
        XCTAssertEqual(decoded.sequence, 4)
    }

    func testForeignAndMalformedMessagesAreRejected() {
        XCTAssertNil(WatchRestSnapshot.decode(["kind": "relay"]))
        XCTAssertNil(WatchRestSnapshot.decode(["kind": WatchRestSnapshot.kind]))
        XCTAssertNil(
            WatchRestSnapshot.decode([
                "kind": WatchRestSnapshot.kind,
                "payload": "not json",
            ])
        )
    }

    // MARK: - Policy

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        launch: String = "L1",
        sequence: Int = 1,
        endsAt: Date? = nil,
        label: String? = nil
    ) -> WatchRestSnapshot {
        WatchRestSnapshot(
            launchId: launch,
            sequence: sequence,
            sessionId: "S1",
            endsAt: endsAt ?? now.addingTimeInterval(90),
            exerciseLabel: label
        )
    }

    func testShowWhenThePhoneIsIdle() {
        let decision = WatchRestMirrorPolicy.decide(
            snapshot(label: "Bench Press"),
            lastLaunchId: nil,
            lastSequence: 0,
            phoneOwnsActivity: false,
            watchActivityShowing: false,
            now: now
        )
        XCTAssertEqual(
            decision.action,
            .show(endDate: now.addingTimeInterval(90), label: "Bench Press")
        )
        XCTAssertTrue(decision.recordSequence)
    }

    func testDefaultsTheLabelToRest() {
        let decision = WatchRestMirrorPolicy.decide(
            snapshot(),
            lastLaunchId: nil,
            lastSequence: 0,
            phoneOwnsActivity: false,
            watchActivityShowing: false,
            now: now
        )
        XCTAssertEqual(
            decision.action,
            .show(endDate: now.addingTimeInterval(90), label: "Rest")
        )
    }

    func testPhoneOwnedRestWins() {
        let decision = WatchRestMirrorPolicy.decide(
            snapshot(sequence: 5),
            lastLaunchId: "L1",
            lastSequence: 4,
            phoneOwnsActivity: true,
            watchActivityShowing: false,
            now: now
        )
        XCTAssertEqual(decision.action, .ignore)
        XCTAssertFalse(decision.recordSequence)
    }

    func testDuplicateDeliveryIsIgnored() {
        let decision = WatchRestMirrorPolicy.decide(
            snapshot(sequence: 4),
            lastLaunchId: "L1",
            lastSequence: 4,
            phoneOwnsActivity: false,
            watchActivityShowing: true,
            now: now
        )
        XCTAssertEqual(decision.action, .ignore)
        XCTAssertFalse(decision.recordSequence)
    }

    func testRelaunchedWatchIsNeverStale() {
        let decision = WatchRestMirrorPolicy.decide(
            snapshot(launch: "L2", sequence: 1),
            lastLaunchId: "L1",
            lastSequence: 900,
            phoneOwnsActivity: false,
            watchActivityShowing: false,
            now: now
        )
        XCTAssertEqual(
            decision.action,
            .show(endDate: now.addingTimeInterval(90), label: "Rest")
        )
    }

    func testNoRestDismissesOnlyAMirroredActivity() {
        let dismiss = WatchRestMirrorPolicy.decide(
            WatchRestSnapshot(launchId: "L1", sequence: 2, sessionId: "S1", endsAt: nil),
            lastLaunchId: "L1",
            lastSequence: 1,
            phoneOwnsActivity: false,
            watchActivityShowing: true,
            now: now
        )
        XCTAssertEqual(dismiss.action, .dismiss)

        let keep = WatchRestMirrorPolicy.decide(
            WatchRestSnapshot(launchId: "L1", sequence: 2, sessionId: "S1", endsAt: nil),
            lastLaunchId: "L1",
            lastSequence: 1,
            phoneOwnsActivity: false,
            watchActivityShowing: false,
            now: now
        )
        XCTAssertEqual(keep.action, .ignore)
    }

    func testRestThatEndedBeforeDeliveryNeverShows() {
        let decision = WatchRestMirrorPolicy.decide(
            WatchRestSnapshot(
                launchId: "L1",
                sequence: 2,
                sessionId: "S1",
                endsAt: now.addingTimeInterval(-5)
            ),
            lastLaunchId: "L1",
            lastSequence: 1,
            phoneOwnsActivity: false,
            watchActivityShowing: false,
            now: now
        )
        XCTAssertEqual(decision.action, .ignore)
    }

    // MARK: - Mirror

    func testMirrorAppliesShowThenDismiss() throws {
        let presenter = StubRestPresenter()
        let mirror = WatchRestMirror(presenter: presenter)

        XCTAssertTrue(mirror.handle(try XCTUnwrap(snapshot(label: "Squat").message), now: now))
        XCTAssertEqual(presenter.shown.count, 1)
        XCTAssertEqual(presenter.shown.first?.label, "Squat")
        XCTAssertTrue(presenter.isShowingWatchRest)

        let end = WatchRestSnapshot(
            launchId: "L1", sequence: 2, sessionId: "S1", endsAt: nil
        )
        XCTAssertTrue(mirror.handle(try XCTUnwrap(end.message), now: now))
        XCTAssertEqual(presenter.dismissCount, 1)
        XCTAssertFalse(presenter.isShowingWatchRest)
    }

    func testMirrorClosesTheCardOnceTheRestHasElapsed() throws {
        let presenter = StubRestPresenter()
        let mirror = WatchRestMirror(presenter: presenter)
        XCTAssertTrue(mirror.handle(try XCTUnwrap(snapshot().message), now: now))
        XCTAssertEqual(presenter.shown.count, 1)

        mirror.dismissIfElapsed(now: now.addingTimeInterval(30))
        XCTAssertEqual(presenter.dismissCount, 0)

        mirror.dismissIfElapsed(now: now.addingTimeInterval(120))
        XCTAssertEqual(presenter.dismissCount, 1)
        XCTAssertFalse(presenter.isShowingWatchRest)
    }

    func testMirrorIgnoresNonRestMessages() {
        let presenter = StubRestPresenter()
        let mirror = WatchRestMirror(presenter: presenter)
        XCTAssertFalse(mirror.handle(["kind": "relay"], now: now))
        XCTAssertTrue(presenter.shown.isEmpty)
    }
}

@MainActor
private final class StubRestPresenter: RestActivityPresenting {
    struct Shown: Equatable {
        let endDate: Date
        let label: String
        let workoutId: String
    }

    var shown: [Shown] = []
    var dismissCount = 0
    var isShowingPhoneRest = false
    private(set) var isShowingWatchRest = false

    func showWatchRest(endDate: Date, exerciseLabel: String, workoutId: String) {
        shown.append(Shown(endDate: endDate, label: exerciseLabel, workoutId: workoutId))
        isShowingWatchRest = true
    }

    func endWatchRest() {
        dismissCount += 1
        isShowingWatchRest = false
    }
}
