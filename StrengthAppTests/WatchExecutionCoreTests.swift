import XCTest

@testable import StrengthApp
import StrengthCore

/// Phase 6.3a: the platform-neutral execution primitives, with no watch app wiring.
final class WatchExecutionCoreTests: XCTestCase {
    private var fileURL: URL!
    private var clock: Date!
    private var store: OfflineCaptureStore!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-execution-\(UUID().uuidString).json")
        clock = Date(timeIntervalSince1970: 1_800_000_000)
        store = OfflineCaptureStore(fileURL: fileURL, now: { [unowned self] in self.clock })
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    // MARK: - Network state

    func testOnlyASuccessfulHomeCallMarksTheSessionOnline() {
        var policy = HomeNetworkPolicy()
        XCTAssertEqual(policy.state, .unknown)

        policy.failed()
        XCTAssertEqual(policy.state, .offline)

        policy.succeeded(host: "home.local")
        XCTAssertEqual(policy.state, .online(host: "home.local"))
        XCTAssertTrue(policy.state.isOnline)
        XCTAssertEqual(policy.state.host, "home.local")

        // A later failure while online is offline again; there is no "reachable" shortcut.
        policy.failed()
        XCTAssertFalse(policy.state.isOnline)
    }

    // MARK: - Retry ladder

    func testRetryLadderFollowsTheScheduleAndStopsAfterFifteenMinutes() {
        var ladder = RetryLadder()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var now = start
        var scheduled: [TimeInterval] = []

        for _ in 0..<6 {
            guard let next = ladder.failed(at: now) else { break }
            scheduled.append(next.timeIntervalSince(start))
            now = next
        }

        // The last wait is clamped so the final attempt lands on the 15-minute boundary.
        XCTAssertEqual(scheduled, [5, 20, 80, 380, 680, 900])
        XCTAssertNil(ladder.failed(at: now), "No attempt may be scheduled after the 15-minute window")
        XCTAssertTrue(ladder.isExhausted(at: now))
    }

    func testSuccessResetsTheLadderAndForegroundRestartsAnExhaustedWindow() {
        var ladder = RetryLadder()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var now = start
        while let next = ladder.failed(at: now) { now = next }
        XCTAssertTrue(ladder.isExhausted(at: now))

        let restarted = ladder.restartWindow(at: now)
        XCTAssertEqual(restarted, now)
        XCTAssertEqual(ladder.attempt, 0)
        XCTAssertEqual(ladder.failed(at: now), now.addingTimeInterval(5))

        ladder.succeeded()
        XCTAssertEqual(ladder.attempt, 0)
        XCTAssertFalse(ladder.isExhausted(at: now))
        XCTAssertEqual(ladder.delay(forAttempt: 1), 5)
        XCTAssertEqual(ladder.delay(forAttempt: 9), 300, "The last delay repeats")
    }

    func testRestartWindowDoesNothingWhileTheBurstStillHasTime() {
        var ladder = RetryLadder()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNotNil(ladder.failed(at: start))
        XCTAssertNil(ladder.restartWindow(at: start.addingTimeInterval(10)))
        XCTAssertEqual(ladder.attempt, 1)
    }

    // MARK: - Server clock

    func testClockOffsetAndFutureClamp() {
        let local = Date(timeIntervalSince1970: 1_800_000_000)
        // The watch is five minutes fast: server time is local minus 300s.
        let serverClock = ServerClock(serverTime: local.addingTimeInterval(-300), receivedAt: local)
        XCTAssertEqual(serverClock.offset, -300)
        XCTAssertTrue(serverClock.isPlausible)

        let past = local.addingTimeInterval(-600)
        XCTAssertEqual(
            serverClock.stamp(action: past, localNow: local),
            past.addingTimeInterval(-300)
        )

        // A stamp captured with the fast clock cannot land more than a minute in the future.
        let skewed = local.addingTimeInterval(299)
        let ceiling = local.addingTimeInterval(60)
        XCTAssertEqual(
            serverClock.stamp(action: skewed, localNow: local),
            ceiling.addingTimeInterval(-300)
        )
        XCTAssertFalse(ServerClock(offset: 2 * 24 * 60 * 60).isPlausible)
    }

    func testEncodedStampIsUtcWithFractionalSeconds() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let encoded = ServerClock.encodedISO(date)
        XCTAssertTrue(encoded.hasSuffix("Z"))
        XCTAssertTrue(encoded.contains("."))
        let parsed = ISO8601DateFormatter()
        parsed.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(parsed.date(from: encoded), date)
    }

    // MARK: - Rest interval

    func testRestIntervalIsPersistedAsAnEndDateAcrossAReload() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let record = WatchSessionRecord(
            sessionUUID: "session-1",
            startedAt: start,
            rest: RestInterval(startedAt: start, prescribedSeconds: 180)
        )
        _ = try store.setSession(record)

        let reloaded = try XCTUnwrap(try store.load().session)
        var rest = try XCTUnwrap(reloaded.rest)
        XCTAssertEqual(rest.remaining(at: start.addingTimeInterval(60)), 120)
        XCTAssertFalse(rest.isComplete(at: start.addingTimeInterval(179)))

        rest.extend(by: 15)
        XCTAssertEqual(rest.addedSeconds, 15)
        XCTAssertEqual(rest.remaining(at: start.addingTimeInterval(180)), 15)
        XCTAssertTrue(rest.isComplete(at: start.addingTimeInterval(195)))

        var updated = reloaded
        updated.rest = rest
        _ = try store.setSession(updated)
        let afterExtend = try XCTUnwrap(try store.load().session?.rest)
        XCTAssertEqual(afterExtend.addedSeconds, 15)
        XCTAssertEqual(afterExtend.endsAt, rest.endsAt)
    }

    func testRestFinishRecordsTheOutcomeOnce() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var rest = RestInterval(startedAt: start, prescribedSeconds: 120)
        XCTAssertNotNil(rest.finish(at: start.addingTimeInterval(30), outcome: .skipped))
        XCTAssertEqual(rest.outcome, .skipped)
        XCTAssertEqual(rest.actualSeconds, 30)
        XCTAssertNil(rest.finish(at: start.addingTimeInterval(40), outcome: .completed))
    }

    // MARK: - Durable queue ordering

    func testPersistBeforeSendPreservesOrderAndOnlyAcknowledgedWorkLeavesTheQueue() throws {
        let first = OfflineOperation(
            operationId: "op-1",
            workoutId: "workout-1",
            body: .addSet(addSet(setIndex: 1)),
            createdAt: clock,
            localSetId: -1
        )
        let second = OfflineOperation(
            operationId: "op-2",
            workoutId: "workout-1",
            body: .addSet(addSet(setIndex: 2)),
            createdAt: clock.addingTimeInterval(30),
            localSetId: -2
        )
        _ = try store.record(first)
        _ = try store.record(second)

        XCTAssertEqual(try store.replayable().map(\.operationId), ["op-1", "op-2"])

        // An attempted-but-unacknowledged operation must stay queued and keep its place.
        _ = try store.markAttempted("op-1")
        XCTAssertEqual(try store.replayable().map(\.operationId), ["op-1", "op-2"])

        _ = try store.updateState(operationId: "op-1", state: .synced)
        XCTAssertEqual(try store.replayable().map(\.operationId), ["op-2"])
    }

    // MARK: - Finish intent

    func testFinishIntentSurvivesAReloadBeforeTheServerAcknowledges() throws {
        let endedAt = Date(timeIntervalSince1970: 1_800_003_600)
        let record = WatchSessionRecord(
            sessionUUID: "session-1",
            startedAt: endedAt.addingTimeInterval(-3_600),
            planRevision: 4,
            clockOffsetSeconds: -12,
            finish: FinishIntent(endedAt: endedAt, sessionRpe: 8)
        )
        _ = try store.setSession(record)

        let reloaded = try XCTUnwrap(try store.load().session)
        let finish = try XCTUnwrap(reloaded.finish)
        XCTAssertEqual(finish.endedAt, endedAt)
        XCTAssertEqual(finish.sessionRpe, 8)
        XCTAssertEqual(finish.hkState, .pending)
        XCTAssertFalse(finish.serverAcked)
        XCTAssertEqual(reloaded.planRevision, 4)
        XCTAssertEqual(reloaded.clock?.offset, -12)
    }

    // MARK: - Compatibility

    func testACaptureFileWrittenBeforePhase63StillLoads() throws {
        let legacy = """
        {"version":1,"activeWorkout":null,"operations":[],
         "updatedAt":"2026-11-11T10:00:00Z"}
        """
        try Data(legacy.utf8).write(to: fileURL)

        let capture = try store.load()
        XCTAssertNil(capture.session)
        XCTAssertEqual(capture.version, 1)
    }

    private func addSet(setIndex: Int) -> AddSetRequest {
        AddSetRequest(
            exerciseId: "competition_squat",
            loadKg: 140,
            reps: 5,
            rir: 2,
            velocityMps: nil,
            setIndex: setIndex,
            planItemIndex: 1,
            performedAt: nil
        )
    }
}
