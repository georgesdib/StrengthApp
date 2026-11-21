import XCTest
import StrengthCore
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

    func testRestExtendedFromTheLiveActivityAppliesWithoutARelaunch() {
        let defaults = UserDefaults(suiteName: "rest-timer-\(UUID().uuidString)")!
        let timer = RestTimerModel(defaults: defaults)
        let anchor = Date().addingTimeInterval(-10)
        timer.start(seconds: 120, startedAt: anchor, workoutId: "w1")

        let extended = RestActivityStore.extend(by: 15, in: defaults)

        XCTAssertEqual(extended?.addedSeconds, 15)
        XCTAssertNil(timer.reconcileExternalChanges(workoutId: "w1"), "an extension records nothing itself")
        XCTAssertEqual(timer.addedSeconds, 15)
        XCTAssertEqual(timer.endDate, anchor.addingTimeInterval(135))
        XCTAssertEqual(RestActivityStore.takeExtension(from: defaults), 15)
        XCTAssertNil(RestActivityStore.takeExtension(from: defaults), "consumed once")
    }

    func testSkipFromTheLiveActivityIsReturnedOnceForRecording() {
        let defaults = UserDefaults(suiteName: "rest-timer-\(UUID().uuidString)")!
        let timer = RestTimerModel(defaults: defaults)
        let anchor = Date().addingTimeInterval(-20)
        timer.start(seconds: 120, planItemIndex: 3, exerciseId: "bench_press", startedAt: anchor, workoutId: "w1")
        let tap = Date()

        XCTAssertNotNil(RestActivityStore.skip(at: tap, in: defaults))

        let result = timer.reconcileExternalChanges(workoutId: "w1")
        XCTAssertEqual(result?.outcome, "skipped")
        XCTAssertEqual(result?.endedAt, tap)
        XCTAssertEqual(result?.actualSeconds, max(0, Int(tap.timeIntervalSince(anchor))))
        XCTAssertEqual(result?.planItemIndex, 3)
        XCTAssertNil(timer.endDate, "the interval is cleared, not merely paused")
        XCTAssertNil(timer.reconcileExternalChanges(workoutId: "w1"), "the completion is consumed once")
    }

    func testASkipFromAnotherWorkoutIsNotAttributed() {
        let defaults = UserDefaults(suiteName: "rest-timer-\(UUID().uuidString)")!
        let timer = RestTimerModel(defaults: defaults)
        timer.start(seconds: 120, startedAt: Date().addingTimeInterval(-10), workoutId: "w1")
        XCTAssertNotNil(RestActivityStore.skip(in: defaults))

        XCTAssertNil(timer.reconcileExternalChanges(workoutId: "w2"))
        XCTAssertNil(RestActivityStore.takeCompletion(from: defaults), "the stale completion is consumed")
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
