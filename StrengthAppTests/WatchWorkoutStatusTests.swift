import XCTest
import StrengthCore

final class WatchWorkoutStatusTests: XCTestCase {
    private func status(
        phase: String,
        pending: Int = 0,
        acknowledged: Bool = false,
        workoutId: String? = "w1"
    ) -> WatchWorkoutStatus {
        WatchWorkoutStatus(
            workoutId: workoutId,
            sessionId: "s1",
            pendingCount: pending,
            phase: phase,
            finishAcknowledged: acknowledged
        )
    }

    func testAnActiveOrFinishingSessionKeepsTheCard() {
        XCTAssertFalse(status(phase: "active").sessionEnded)
        XCTAssertFalse(status(phase: "finishing", pending: 2).sessionEnded)
    }

    func testAFinishedOrAbandonedSessionEndsTheCard() {
        XCTAssertTrue(status(phase: "finished").sessionEnded)
        XCTAssertTrue(status(phase: "abandoned").sessionEnded)
    }

    func testAnEndedElsewhereSessionEndsTheCard() {
        XCTAssertTrue(status(phase: "ended(StrengthCore.WatchEndedReason.completed)").sessionEnded)
    }

    func testAnAcknowledgedFinishEndsTheCard() {
        XCTAssertTrue(status(phase: "finishing", pending: 0, acknowledged: true).sessionEnded)
    }

    func testAStatusWithoutAWorkoutNeverEndsACard() {
        XCTAssertFalse(status(phase: "finished", workoutId: nil).sessionEnded)
    }
}
