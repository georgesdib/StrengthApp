import XCTest
import StrengthCore

/// The watch sends the server an `Idempotency-Key`, which must be a UUID and must be identical
/// when the same mutation is retried from the offline ladder or after a relaunch.
final class OperationIDTests: XCTestCase {
    func testDerivedKeyIsAUUID() {
        XCTAssertNotNil(UUID(uuidString: OperationID.derived("start:plan-1")))
        XCTAssertNotNil(UUID(uuidString: OperationID.derived("abandon:workout-1")))
    }

    func testDerivedKeyIsStableAcrossAttempts() {
        XCTAssertEqual(OperationID.derived("start:plan-1"), OperationID.derived("start:plan-1"))
    }

    func testDifferentOperationsDeriveDifferentKeys() {
        XCTAssertNotEqual(OperationID.derived("start:plan-1"), OperationID.derived("start:plan-2"))
        XCTAssertNotEqual(
            OperationID.derived("start:plan-1"),
            OperationID.derived("abandon:plan-1")
        )
    }

    func testDerivedKeyIsLowercaseHexWithDashes() {
        let key = OperationID.derived("start:plan-1")
        XCTAssertEqual(key.count, 36)
        XCTAssertEqual(key, key.lowercased())
        XCTAssertEqual(key.filter { $0 == "-" }.count, 4)
    }
}
