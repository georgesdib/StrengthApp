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

    func testTheBuildStampTravelsWithTheStatus() {
        let status = WatchWorkoutStatus(
            workoutId: "w1",
            sessionId: "s1",
            pendingCount: 0,
            phase: "active",
            finishAcknowledged: false,
            build: "c79a86f"
        )
        guard let message = status.message,
              let decoded = WatchWorkoutStatus.decode(message) else {
            return XCTFail("the status did not round-trip through the relay payload")
        }
        XCTAssertEqual(decoded.build, "c79a86f")
    }

    func testAStatusFromAWatchWithoutAStampStillDecodes() {
        // A watch built before the stamp existed must not break the phone's relay.
        let legacy = #"{"workoutId":"w1","sessionId":"s1","pendingCount":0,"phase":"active","finishAcknowledged":false,"updatedAt":"2026-11-27T00:00:00Z"}"#
        guard let decoded = WatchWorkoutStatus.decode(["watch_status": legacy]) else {
            return XCTFail("a status without a build did not decode")
        }
        XCTAssertNil(decoded.build)
        XCTAssertFalse(decoded.sessionEnded)
    }
}
