import XCTest

@testable import StrengthApp
import StrengthCore

@MainActor
final class WatchHealthKitFinalizerTests: XCTestCase {
    private final class FakeRecorder: HealthKitSaving {
        var hasLiveBuilder = true
        var existingWorkout = false
        var queryFailure: HealthKitSaveFailure?
        var liveFailure: HealthKitSaveFailure?
        var minimalFailure: HealthKitSaveFailure?
        var effortFailure: HealthKitSaveFailure?
        var liveCalls = 0
        var minimalCalls = 0
        var effortCalls = 0
        var endCalls = 0
        var lastLiveEndedAt: Date?
        var lastMinimalStart: Date?
        var lastEffort: Double?

        func hasWorkout(externalUUID: String) async throws -> Bool {
            if let queryFailure { throw queryFailure }
            return existingWorkout
        }

        func finishLiveWorkout(externalUUID: String, endedAt: Date) async throws {
            liveCalls += 1
            lastLiveEndedAt = endedAt
            if let liveFailure { throw liveFailure }
        }

        func saveMinimalWorkout(
            externalUUID: String, startedAt: Date, endedAt: Date
        ) async throws {
            minimalCalls += 1
            lastMinimalStart = startedAt
            if let minimalFailure { throw minimalFailure }
        }

        func saveEffort(externalUUID: String, effort: Double) async throws {
            effortCalls += 1
            lastEffort = effort
            if let effortFailure { throw effortFailure }
        }

        func endWithoutSaving() async { endCalls += 1 }
    }

    private let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private let endedAt = Date(timeIntervalSince1970: 1_800_003_600)

    private func finalize(
        recorder: FakeRecorder,
        state: HealthKitSaveState = .pending,
        attempts: Int = 0,
        effortState: EffortDeliveryState? = .pending,
        effortAttempts: Int? = 0,
        effort: Double? = 8,
        manual: Bool = false
    ) async -> HealthKitFinalizationOutcome {
        await HealthKitFinalizer.finalize(
            externalUUID: "session-1",
            startedAt: startedAt,
            endedAt: endedAt,
            effort: effort,
            state: state,
            attempts: attempts,
            effortState: effortState,
            effortAttempts: effortAttempts,
            manual: manual,
            recorder: recorder
        )
    }

    func testSavedWorkoutAndEffortDoNothing() async {
        let recorder = FakeRecorder()
        let outcome = await finalize(recorder: recorder, state: .saved, effortState: .saved)
        XCTAssertEqual(outcome.state, .saved)
        XCTAssertEqual(recorder.liveCalls + recorder.minimalCalls + recorder.effortCalls, 0)
    }

    func testAnExistingWorkoutIsNeverSavedTwice() async {
        let recorder = FakeRecorder()
        recorder.existingWorkout = true

        let outcome = await finalize(recorder: recorder)

        XCTAssertEqual(outcome.state, .saved)
        XCTAssertEqual(recorder.liveCalls, 0)
        XCTAssertEqual(recorder.minimalCalls, 0)
    }

    func testALiveBuilderFinishesWithTheOriginalEnd() async {
        let recorder = FakeRecorder()
        let outcome = await finalize(recorder: recorder)
        XCTAssertEqual(outcome.state, .saved)
        XCTAssertEqual(recorder.liveCalls, 1)
        XCTAssertEqual(recorder.minimalCalls, 0)
        XCTAssertEqual(recorder.lastLiveEndedAt, endedAt)
    }

    func testWithoutABuilderOneBackdatedWorkoutIsSaved() async {
        let recorder = FakeRecorder()
        recorder.hasLiveBuilder = false
        let outcome = await finalize(recorder: recorder)
        XCTAssertEqual(outcome.state, .saved)
        XCTAssertEqual(recorder.minimalCalls, 1)
        XCTAssertEqual(recorder.lastMinimalStart, startedAt)
    }

    func testTransientFailureStaysPendingAndCounts() async {
        let recorder = FakeRecorder()
        recorder.liveFailure = .transient("busy")
        let outcome = await finalize(recorder: recorder, attempts: 2)
        XCTAssertEqual(outcome.state, .pending)
        XCTAssertEqual(outcome.attempts, 3)
        XCTAssertEqual(outcome.failure, "busy")
    }

    func testFiveTransientFailuresBecomeUnsaved() async {
        let recorder = FakeRecorder()
        recorder.liveFailure = .transient("busy")
        let outcome = await finalize(recorder: recorder, attempts: 4)
        XCTAssertEqual(outcome.state, .unsaved)
        XCTAssertEqual(outcome.attempts, 5)
    }

    func testDefinitiveFailureIsUnsavedImmediately() async {
        let recorder = FakeRecorder()
        recorder.liveFailure = .definitive("authorisation denied")
        let outcome = await finalize(recorder: recorder)
        XCTAssertEqual(outcome.state, .unsaved)
        XCTAssertEqual(outcome.failure, "authorisation denied")
        XCTAssertEqual(outcome.attempts, 0)
    }

    func testAFailedExistenceQueryNeverSaves() async {
        let recorder = FakeRecorder()
        recorder.queryFailure = .transient("query failed")

        let outcome = await finalize(recorder: recorder, attempts: 1)

        XCTAssertEqual(outcome.state, .pending, "absence was not established")
        XCTAssertEqual(outcome.attempts, 2)
        XCTAssertEqual(recorder.liveCalls + recorder.minimalCalls, 0)
    }

    func testUnsavedHasNoAutomaticRetryButAManualOneWorks() async {
        let recorder = FakeRecorder()

        let automatic = await finalize(recorder: recorder, state: .unsaved, attempts: 2)
        XCTAssertEqual(automatic.state, .unsaved)
        XCTAssertEqual(recorder.liveCalls + recorder.minimalCalls, 0)

        let manual = await finalize(
            recorder: recorder, state: .unsaved, attempts: 2, manual: true
        )
        XCTAssertEqual(manual.state, .saved)
        XCTAssertEqual(recorder.liveCalls, 1)
    }

    func testAManualRetryThatFailsAgainStaysUnsaved() async {
        let recorder = FakeRecorder()
        recorder.liveFailure = .transient("busy")
        let outcome = await finalize(
            recorder: recorder, state: .unsaved, attempts: 5, manual: true
        )
        XCTAssertEqual(outcome.state, .unsaved)
    }

    func testEffortIsSavedAfterTheWorkout() async {
        let recorder = FakeRecorder()
        let outcome = await finalize(recorder: recorder)
        XCTAssertEqual(outcome.effortState, .saved)
        XCTAssertEqual(recorder.effortCalls, 1)
        XCTAssertEqual(recorder.lastEffort, 8)
    }

    func testEffortIsRetriedWithoutSavingAnotherWorkout() async {
        let recorder = FakeRecorder()
        let outcome = await finalize(
            recorder: recorder, state: .saved, effortState: .pending
        )
        XCTAssertEqual(outcome.state, .saved)
        XCTAssertEqual(recorder.effortCalls, 1)
        XCTAssertEqual(recorder.liveCalls + recorder.minimalCalls, 0)
    }

    func testEffortFailureKeepsTheWorkoutAndStaysPending() async {
        let recorder = FakeRecorder()
        recorder.effortFailure = .transient("busy")
        let outcome = await finalize(recorder: recorder, effortAttempts: 0)
        XCTAssertEqual(outcome.state, .saved)
        XCTAssertEqual(outcome.effortState, .pending)
        XCTAssertEqual(outcome.effortAttempts, 1)
    }

    func testDefinitiveEffortFailureBecomesUnavailable() async {
        let recorder = FakeRecorder()
        recorder.effortFailure = .definitive("not supported")
        let outcome = await finalize(recorder: recorder)
        XCTAssertEqual(outcome.state, .saved)
        XCTAssertEqual(outcome.effortState, .unavailable)
    }

    // MARK: - Startup coordination

    func testStartupNeedsBothSessionAndCollection() {
        var gate = HealthKitStartGate()
        XCTAssertEqual(gate.sessionStarted(), .waiting)
        XCTAssertEqual(gate.collectionStarted(), .ready)
    }

    func testAFailureWinsOverAPartialStart() {
        var gate = HealthKitStartGate()
        _ = gate.sessionStarted()
        XCTAssertEqual(gate.failed("collection failed"), .failed("collection failed"))
        XCTAssertEqual(gate.collectionStarted(), .failed("collection failed"))
    }

    // MARK: - Heart-rate freshness

    func testHeartRateFreshness() {
        let observed = Date(timeIntervalSince1970: 1_800_000_000)
        let reading = HeartRateReading(bpm: 128, observedAt: observed)
        XCTAssertTrue(reading.isFresh(at: observed.addingTimeInterval(10)))
        XCTAssertTrue(reading.isFresh(at: observed.addingTimeInterval(30)))
        XCTAssertFalse(reading.isFresh(at: observed.addingTimeInterval(31)))
    }
}
