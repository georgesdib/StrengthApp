import XCTest

@testable import StrengthApp
import StrengthCore

@MainActor
final class WatchHealthKitFinalizerTests: XCTestCase {
    private final class FakeRecorder: HealthKitSaving {
        var hasLiveBuilder = true
        var existingWorkout = false
        var liveCalls = 0
        var minimalCalls = 0
        var endCalls = 0
        var failures: [HealthKitSaveFailure] = []
        var lastLiveEndedAt: Date?
        var lastMinimalStart: Date?
        var lastEffort: Double?

        func hasWorkout(externalUUID: String) async -> Bool { existingWorkout }

        func finishLiveWorkout(
            externalUUID: String, endedAt: Date, effort: Double?
        ) async throws {
            liveCalls += 1
            lastLiveEndedAt = endedAt
            lastEffort = effort
            if !failures.isEmpty { throw failures.removeFirst() }
        }

        func saveMinimalWorkout(
            externalUUID: String, startedAt: Date, endedAt: Date, effort: Double?
        ) async throws {
            minimalCalls += 1
            lastMinimalStart = startedAt
            lastEffort = effort
            if !failures.isEmpty { throw failures.removeFirst() }
        }

        func endWithoutSaving() async { endCalls += 1 }
    }

    private let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private let endedAt = Date(timeIntervalSince1970: 1_800_003_600)

    private func finalize(
        recorder: FakeRecorder,
        state: HealthKitSaveState = .pending,
        attempts: Int = 0,
        manual: Bool = false
    ) async -> HealthKitFinalizationOutcome {
        await HealthKitFinalizer.finalize(
            externalUUID: "session-1",
            startedAt: startedAt,
            endedAt: endedAt,
            effort: 8,
            state: state,
            attempts: attempts,
            manual: manual,
            recorder: recorder
        )
    }

    func testSavedStateDoesNothing() async {
        let recorder = FakeRecorder()
        let outcome = await finalize(recorder: recorder, state: .saved)
        XCTAssertEqual(outcome.state, .saved)
        XCTAssertEqual(recorder.liveCalls + recorder.minimalCalls, 0)
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
        XCTAssertEqual(recorder.lastEffort, 8)
    }

    func testWithoutABuilderOneBackdatedWorkoutIsSaved() async {
        let recorder = FakeRecorder()
        recorder.hasLiveBuilder = false

        let outcome = await finalize(recorder: recorder)

        XCTAssertEqual(outcome.state, .saved)
        XCTAssertEqual(recorder.minimalCalls, 1)
        XCTAssertEqual(recorder.lastMinimalStart, startedAt, "the original start is kept")
    }

    func testTransientFailureStaysPendingAndCounts() async {
        let recorder = FakeRecorder()
        recorder.failures = [.transient("busy")]

        let outcome = await finalize(recorder: recorder, attempts: 2)

        XCTAssertEqual(outcome.state, .pending)
        XCTAssertEqual(outcome.attempts, 3)
        XCTAssertEqual(outcome.failure, "busy")
    }

    func testFiveTransientFailuresBecomeUnsaved() async {
        let recorder = FakeRecorder()
        recorder.failures = [.transient("busy")]

        let outcome = await finalize(recorder: recorder, attempts: 4)

        XCTAssertEqual(outcome.state, .unsaved)
        XCTAssertEqual(outcome.attempts, 5)
    }

    func testDefinitiveFailureIsUnsavedImmediately() async {
        let recorder = FakeRecorder()
        recorder.failures = [.definitive("authorisation denied")]

        let outcome = await finalize(recorder: recorder)

        XCTAssertEqual(outcome.state, .unsaved)
        XCTAssertEqual(outcome.failure, "authorisation denied")
        XCTAssertEqual(outcome.attempts, 0, "a definitive failure does not consume attempts")
    }

    func testUnsavedHasNoAutomaticRetryButAManualOneWorks() async {
        let recorder = FakeRecorder()

        let automatic = await finalize(recorder: recorder, state: .unsaved, attempts: 2)
        XCTAssertEqual(automatic.state, .unsaved)
        XCTAssertEqual(recorder.liveCalls + recorder.minimalCalls, 0)

        let manual = await finalize(recorder: recorder, state: .unsaved, attempts: 2, manual: true)
        XCTAssertEqual(manual.state, .saved)
        XCTAssertEqual(recorder.liveCalls, 1)
    }

    func testAManualRetryThatFailsAgainStaysUnsaved() async {
        let recorder = FakeRecorder()
        recorder.failures = [.transient("busy")]

        let outcome = await finalize(
            recorder: recorder, state: .unsaved, attempts: 5, manual: true
        )

        XCTAssertEqual(outcome.state, .unsaved, "manual retries never re-arm auto retries")
        XCTAssertEqual(outcome.attempts, 6)
    }
}
