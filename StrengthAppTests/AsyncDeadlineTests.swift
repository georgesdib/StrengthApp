import XCTest

import StrengthCore

/// The watch screen must never be able to sit on a loading state forever: a hung request has to
/// become a bounded failure the screen can explain.
final class AsyncDeadlineTests: XCTestCase {
    func testASlowOperationFailsAtTheDeadline() async {
        let started = Date()
        do {
            _ = try await AsyncDeadline.run(seconds: 0.2) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 1
            }
            XCTFail("expected the deadline to fire")
        } catch let exceeded as AsyncDeadline.Exceeded {
            XCTAssertEqual(exceeded.seconds, 0.2)
            XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the deadline did not fire promptly")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testAFastOperationReturnsItsValue() async throws {
        let value = try await AsyncDeadline.run(seconds: 5) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testAnOperationErrorWinsOverTheDeadline() async {
        struct Failure: Error {}
        do {
            _ = try await AsyncDeadline.run(seconds: 5) {
                throw Failure()
            }
            XCTFail("expected the operation error")
        } catch is Failure {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
