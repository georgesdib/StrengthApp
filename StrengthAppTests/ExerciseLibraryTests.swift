import XCTest
@testable import StrengthApp

@MainActor
final class ExerciseLibraryTests: XCTestCase {
    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    func testExerciseDetailDecodesConfigurationAndE1RM() throws {
        let json = #"""
        {
          "exercise": {
            "id": "competition_squat",
            "display": "Competition Squat",
            "pattern": "squat",
            "source": "base"
          },
          "properties": {
            "primary_muscles": ["quadriceps", "glutes"],
            "e1rm_applicable": true,
            "loadable": true
          },
          "e1rm_applicable": true,
          "e1rm": {
            "exercise_id": "competition_squat",
            "from": "2025-11-08",
            "to": "2026-11-08",
            "basis": "raw_formula_epley_rir",
            "decay": "not_applied",
            "calibration": "not_applied",
            "points": [
              {"date": "2026-11-08", "kg": 163.3, "rolling_median_kg": 163.3, "n_window": 1}
            ],
            "degraded": [],
            "breaks": [],
            "summary": {
              "n": 1,
              "status": "points_only",
              "latest": {"date": "2026-11-08", "kg": 163.3},
              "best": {"date": "2026-11-08", "kg": 163.3},
              "recent_median_kg": 163.3,
              "change_from_median_kg": 0,
              "trend_statement": null
            }
          },
          "e1rm_reason": null
        }
        """#
        let detail = try decoder.decode(
            ExerciseDetailResponse.self, from: Data(json.utf8)
        )
        XCTAssertEqual(detail.exercise.id, "competition_squat")
        XCTAssertEqual(detail.properties["loadable"], .bool(true))
        XCTAssertEqual(detail.e1rm?.summary.latest?.kg, 163.3)
        XCTAssertEqual(detail.e1rm?.points.first?.nWindow, 1)
    }

    func testExerciseHistoryDecodesSetsAndEquivalents() throws {
        let json = #"""
        {
          "exercise_id": "back_extension",
          "included_exercises": [
            {"id": "back_extension", "display": "Back Extension"},
            {"id": "hyperextension", "display": "Hyperextension"}
          ],
          "limit": 20,
          "offset": 0,
          "total": 2,
          "has_more": false,
          "start": null,
          "end": null,
          "sessions": [
            {
              "session_id": "session-1",
              "occurred_on": "2026-11-08",
              "session_type": "hinge",
              "sets": [
                {
                  "set_index": 1,
                  "load_kg": 40.0,
                  "load_basis": "external",
                  "reps": 10,
                  "reps_unit": "reps",
                  "rir": 2,
                  "tonnage_kg": 400.0
                }
              ]
            }
          ]
        }
        """#
        let history = try decoder.decode(
            ExerciseHistoryResponse.self, from: Data(json.utf8)
        )
        XCTAssertEqual(history.total, 2)
        XCTAssertEqual(history.includedExercises.count, 2)
        XCTAssertEqual(history.sessions.first?.sets.first?.rir, 2)
        XCTAssertTrue(history.sessions.first?.sets.first?.summary.contains("RIR 2") == true)
    }
}
