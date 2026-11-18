import XCTest
@testable import StrengthApp

@MainActor
final class RestTimerTests: XCTestCase {
    func testAPastAnchoredRestCountsTheEntryTimeAsRest() {
        let timer = RestTimerModel()
        let anchor = Date().addingTimeInterval(-60)

        timer.start(seconds: 120, startedAt: anchor)

        XCTAssertEqual(timer.startedAt, anchor)
        XCTAssertEqual(timer.endDate, anchor.addingTimeInterval(120))
        XCTAssertTrue((58...61).contains(timer.remainingSeconds), "\(timer.remainingSeconds)")
    }

    func testAnAnchorOlderThanTheRestStartsComplete() {
        let timer = RestTimerModel()

        timer.start(seconds: 60, startedAt: Date().addingTimeInterval(-120))

        XCTAssertTrue(timer.isComplete)
        XCTAssertEqual(timer.remainingSeconds, 0)
    }

    func testRestSurvivesARelaunchWhileItIsStillRunning() {
        let defaults = UserDefaults(suiteName: "rest-timer-\(UUID().uuidString)")!
        let anchor = Date().addingTimeInterval(-30)
        let first = RestTimerModel(defaults: defaults)
        first.start(
            seconds: 120,
            planItemIndex: 2,
            exerciseId: "competition_squat",
            startedAt: anchor,
            workoutId: "w1"
        )

        let second = RestTimerModel(defaults: defaults)
        XCTAssertNil(second.restore(workoutId: "w1"))
        XCTAssertEqual(second.startedAt, anchor)
        XCTAssertEqual(second.prescribedSeconds, 120)
        XCTAssertEqual(second.planItemIndex, 2)
        XCTAssertTrue((88...91).contains(second.remainingSeconds), "\(second.remainingSeconds)")
    }

    func testRestThatEndedWhileTheAppWasGoneIsReturnedAtItsScheduledEnd() {
        let defaults = UserDefaults(suiteName: "rest-timer-\(UUID().uuidString)")!
        let anchor = Date().addingTimeInterval(-180)
        let first = RestTimerModel(defaults: defaults)
        first.start(
            seconds: 60,
            planItemIndex: 1,
            exerciseId: "bench_press",
            startedAt: anchor,
            workoutId: "w1"
        )

        let second = RestTimerModel(defaults: defaults)
        let result = second.restore(workoutId: "w1")

        XCTAssertEqual(result?.outcome, "completed")
        XCTAssertEqual(result?.actualSeconds, 60, "recorded at its real end, not at launch")
        XCTAssertEqual(result?.endedAt, anchor.addingTimeInterval(60))
        XCTAssertEqual(result?.planItemIndex, 1)
        XCTAssertNil(second.restore(workoutId: "w1"), "the interval is consumed once")
    }

    func testARestFromAnotherWorkoutIsDiscarded() {
        let defaults = UserDefaults(suiteName: "rest-timer-\(UUID().uuidString)")!
        let first = RestTimerModel(defaults: defaults)
        first.start(seconds: 120, startedAt: Date(), workoutId: "w1")

        let second = RestTimerModel(defaults: defaults)
        XCTAssertNil(second.restore(workoutId: "w2"))
        XCTAssertNil(second.endDate)
    }
}
