import XCTest
import StrengthCore

/// The plan's VBT target is display-only: decode what the server sent and format it, never
/// derive, clamp or reinterpret it.
final class PrescriptionVelocityTargetTests: XCTestCase {
    private func decode(_ json: String) throws -> PrescriptionItem {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PrescriptionItem.self, from: Data(json.utf8))
    }

    func testTargetDecodesAndFormatsForDisplay() throws {
        let item = try decode(#"""
        {
          "order_index": 0,
          "exercise_id": "competition_squat",
          "sets": 3,
          "reps_low": 3,
          "reps_high": 5,
          "load_kg": 140.0,
          "load_basis": "e1rm",
          "rir_target": 2,
          "effort_model": "rir",
          "velocity_target": 0.35
        }
        """#)

        XCTAssertEqual(item.velocityTarget, 0.35)
        XCTAssertEqual(item.velocityTargetLabel, "0.35 m/s")
        XCTAssertEqual(item.effortLabel, "RIR 2")
    }

    func testMissingTargetHidesTheLabel() throws {
        let item = try decode(#"""
        {
          "order_index": 0,
          "exercise_id": "competition_squat",
          "sets": 3,
          "reps_low": 3,
          "reps_high": 5,
          "load_kg": 140.0,
          "load_basis": "e1rm",
          "rir_target": 2,
          "effort_model": "rir"
        }
        """#)

        XCTAssertNil(item.velocityTarget)
        XCTAssertNil(item.velocityTargetLabel)
    }

    func testNonPositiveTargetIsNotDisplayed() throws {
        let item = try decode(#"""
        {
          "order_index": 0,
          "exercise_id": "competition_squat",
          "sets": 3,
          "reps_low": 3,
          "reps_high": 5,
          "load_kg": 140.0,
          "load_basis": "e1rm",
          "rir_target": 2,
          "effort_model": "rir",
          "velocity_target": 0
        }
        """#)

        XCTAssertEqual(item.velocityTarget, 0)
        XCTAssertNil(item.velocityTargetLabel)
    }
}
