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
}
