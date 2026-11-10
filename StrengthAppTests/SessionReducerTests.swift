import XCTest
import StrengthCore

final class SessionReducerTests: XCTestCase {
    private func workout(_ id: String = "workout-1") -> WorkoutDetail {
        WorkoutDetail(
            workoutId: id,
            prescriptionId: nil,
            forDate: nil,
            sessionType: nil,
            status: "in_progress",
            plan: nil,
            sets: nil,
            forms: nil,
            elapsedSeconds: nil,
            sessionRpe: nil,
            startedAt: nil
        )
    }

    func testOperationBeganSetsSavingAndClearsAmbiguity() {
        let state = SessionState(mutationFailureAmbiguous: true)
        let (next, effects) = SessionReducer.reduce(state, .operationBegan)
        XCTAssertTrue(next.isSaving)
        XCTAssertFalse(next.mutationFailureAmbiguous)
        XCTAssertEqual(effects, [])
    }

    func testSuccessAdoptsWorkoutAndRefreshesPendingMutations() {
        let state = SessionState(isSaving: true, mutationError: "old")
        let (next, effects) = SessionReducer.reduce(state, .operationSucceeded(workout()))
        XCTAssertEqual(next.activeWorkout?.workoutId, "workout-1")
        XCTAssertFalse(next.isSaving)
        XCTAssertNil(next.mutationError)
        XCTAssertEqual(effects, [.refreshPendingMutations])
    }

    func testFailureKeepsErrorAndAmbiguity() {
        let state = SessionState(isSaving: true)
        let (next, effects) = SessionReducer.reduce(
            state,
            .operationFailed(message: "offline", ambiguous: true)
        )
        XCTAssertEqual(next.mutationError, "offline")
        XCTAssertTrue(next.mutationFailureAmbiguous)
        XCTAssertFalse(next.isSaving)
        XCTAssertEqual(effects, [.refreshPendingMutations])
    }

    func testQueuedWorkoutPersistsAndRefreshes() {
        let state = SessionState(isSaving: true)
        let (next, effects) = SessionReducer.reduce(state, .operationQueued(workout("local")))
        XCTAssertEqual(next.activeWorkout?.workoutId, "local")
        XCTAssertFalse(next.isSaving)
        XCTAssertEqual(effects, [.persistActiveWorkout, .refreshPendingMutations])
    }

    func testActiveWorkoutChangePersists() {
        let state = SessionState(activeWorkout: workout("old"))
        let (next, effects) = SessionReducer.reduce(
            state,
            .activeWorkoutChanged(workout("new"))
        )
        XCTAssertEqual(next.activeWorkout?.workoutId, "new")
        XCTAssertEqual(effects, [.persistActiveWorkout])
    }
}
