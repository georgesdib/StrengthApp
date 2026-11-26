import XCTest

@testable import StrengthApp
import StrengthCore

/// DEC-READINESS-06: the old per-lift readiness columns are historical calibration labels, not
/// inputs. The server rejects them on `record_manual`, so the phone must not offer them.
final class ReadinessFormFieldTests: XCTestCase {
    func testLegacyPerLiftReadinessFieldsAreNotOffered() {
        let ids = ReadinessFormView.inputFieldIds
        let legacy = ["squat_readiness", "bench_readiness", "deadlift_readiness"]
        for field in legacy {
            XCTAssertFalse(ids.contains(field), "\(field) is a legacy calibration label, not an input")
        }
    }

    func testFallbackFormOffersTheSeededRegistryOrderPlusTheTwoExtras() {
        XCTAssertEqual(
            ReadinessFormView.inputFieldIds,
            [
                "sleep", "energy", "mood", "stress", "soreness",
                "hrv_ms", "rhr_bpm", "bodyweight_kg", "wearable_score",
            ]
        )
    }
}
