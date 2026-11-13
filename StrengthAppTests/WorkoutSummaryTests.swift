import XCTest
@testable import StrengthApp
import StrengthCore

@MainActor
final class WorkoutSummaryTests: XCTestCase {
    private let session = IOSSession(
        baseURL: URL(string: "http://home.local:8000")!,
        token: "token",
        deviceID: "phone-1"
    )

    func testSummaryDecodesTheAFC2Contract() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let envelope = try decoder.decode(
            WorkoutSummaryEnvelope.self,
            from: Data(Self.summaryJSON.utf8)
        )
        let summary = envelope.summary
        XCTAssertEqual(summary.workoutId, "workout-1")
        XCTAssertEqual(summary.adherence?.status, "available")
        XCTAssertEqual(summary.adherence?.finalPlan?.setCompletion?.numerator, 3)
        XCTAssertEqual(summary.adherence?.finalPlan?.setCompletion?.denominator, 4)
        XCTAssertEqual(summary.adherence?.finalPlan?.setCompletion?.ratio, 0.75)
        XCTAssertEqual(summary.adherence?.quality?.planModified, true)
        XCTAssertEqual(summary.adherence?.changes?.setCountChanged?.first?.sets, 3)
        XCTAssertEqual(summary.vbt?.status, "available")
        XCTAssertEqual(summary.vbt?.quality?.comparableSets, 2)
        XCTAssertEqual(summary.vbt?.quality?.targetMetadata?["computed"], 1)
        XCTAssertEqual(summary.feedback?.srpe, 7)
        XCTAssertEqual(summary.quality?.flags?.first?.code, "sets_without_rir")
        XCTAssertEqual(summary.evidence?.first?.gate, "signal")
        XCTAssertEqual(
            summary.evidence?.first?.limitations?.first,
            "prescription adherence is descriptive; it is not a training outcome"
        )
    }

    func testUnavailableAdherenceCarriesItsReason() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let envelope = try decoder.decode(
            WorkoutSummaryEnvelope.self,
            from: Data(Self.unavailableJSON.utf8)
        )
        XCTAssertEqual(envelope.summary.adherence?.status, "unavailable")
        XCTAssertEqual(envelope.summary.adherence?.reason, "no_prescription_snapshot")
    }

    func testSummaryEndpointUsesTheIOSFacadePath() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(
                request.url?.path,
                "/api/ios/v1/workouts/workout-1/summary"
            )
            return (200, Data(Self.summaryJSON.utf8))
        }
        let client = IOSAPIClient(transport: transport)
        let envelope = try await client.workoutSummary(
            workoutId: "workout-1", session: session
        )
        XCTAssertEqual(envelope.summary.workoutId, "workout-1")
    }

    func testHistoryDetailCarriesTheWorkoutId() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let detail = try decoder.decode(
            HistoryDetail.self,
            from: Data(#"""
            {"session_id":"session-1","workout_id":"workout-1","occurred_on":"2026-11-13"}
            """#.utf8)
        )
        XCTAssertEqual(detail.workoutId, "workout-1")
    }

    private static let summaryJSON = #"""
    {
      "summary": {
        "workout_id": "workout-1",
        "session_id": "session-1",
        "for_date": "2026-11-13",
        "session_type": "squat",
        "status": "completed",
        "adherence": {
          "status": "available",
          "reason": null,
          "original": {"view":"original","status":"available",
            "prescribed_sets":4,"performed_sets":5,"matched_sets":3,
            "missing_sets":1,"extra_sets":1,
            "set_completion":{"numerator":3,"denominator":4,"ratio":0.75},
            "reps":{"attainment":{"numerator":3,"denominator":3,"ratio":1.0},
              "evaluated_sets":3,"within_target":2,"below_target":1,
              "above_target":0,"unavailable_sets":0},
            "load":{"attainment":{"numerator":2,"denominator":3,"ratio":0.6667},
              "evaluated_sets":3,"at_target":2,"below_target":1,
              "above_target":0,"unavailable_sets":0,
              "mean_absolute_deviation_kg":2.5},
            "rir":{"attainment":{"numerator":3,"denominator":3,"ratio":1.0},
              "evaluated_sets":3,"at_target":2,"above_target":1,
              "below_target":0,"unavailable_sets":0,"mean_deviation":0.5},
            "quality":{"unmatched_sets":1,"ambiguous_attribution":0,
              "unavailable_metrics":["missing_actual_rir"]}},
          "final_plan": {"view":"final_plan","status":"available",
            "prescribed_sets":4,"performed_sets":5,"matched_sets":3,
            "missing_sets":1,"extra_sets":1,
            "set_completion":{"numerator":3,"denominator":4,"ratio":0.75},
            "reps":{"attainment":{"numerator":3,"denominator":3,"ratio":1.0},
              "evaluated_sets":3,"within_target":2,"below_target":1,
              "above_target":0,"unavailable_sets":0},
            "load":{"attainment":{"numerator":2,"denominator":3,"ratio":0.6667},
              "evaluated_sets":3,"at_target":2,"below_target":1,
              "above_target":0,"unavailable_sets":0,
              "mean_absolute_deviation_kg":2.5},
            "rir":{"attainment":{"numerator":3,"denominator":3,"ratio":1.0},
              "evaluated_sets":3,"at_target":2,"above_target":1,
              "below_target":0,"unavailable_sets":0,"mean_deviation":0.5},
            "quality":{"unmatched_sets":1,"ambiguous_attribution":0,
              "unavailable_metrics":["missing_actual_rir"]}},
          "changes": {
            "swapped": [], "added": [],
            "removed": [{"plan_item_index":1,"exercise_id":"bench_press","sets":3}],
            "set_count_changed": [{"plan_item_index":0,"exercise_id":"competition_squat","sets":3}],
            "targets_changed": []
          },
          "quality": {
            "plan_modified": true,
            "sets_without_rir": 1,
            "unmatched_sets": {"original":0,"final_plan":1},
            "ambiguous_attribution": {"original":0,"final_plan":0},
            "unattributable_planned_sets": {"original":0,"final_plan":0},
            "unavailable_metrics": []
          }
        },
        "vbt": {
          "status": "available",
          "reason": null,
          "exercises": [{
            "exercise_id":"competition_squat","sets":3,"comparable_sets":2,
            "excluded_sets":1,"mean_signed_delta_mps":0.02,
            "median_signed_delta_mps":0.02,"mean_absolute_error_mps":0.02,
            "within_calibration_band":{"numerator":2,"denominator":2,"ratio":1.0},
            "above_target":{"numerator":1,"denominator":2,"ratio":0.5},
            "below_target":{"numerator":1,"denominator":2,"ratio":0.5}
          }],
          "quality": {
            "logged_sets":3,"working_sets":3,"sets_with_velocity":2,
            "sets_with_valid_velocity":2,"target_sets":2,
            "comparable_sets":2,"excluded_sets":1,"extra_sets":0,
            "target_metadata":{"computed":1},"reasons":{}
          }
        },
        "feedback": {
          "srpe":7,"duration_min":50,"duration_source":"measured",
          "session_load_au":320,"session_load_status":"observed","productivity":4
        },
        "quality": {
          "flags":[{"code":"sets_without_rir","detail":"1"}],
          "coverage":{"rir":0.8,"e1rm":1.0}
        },
        "evidence": [{
          "evidence_id":"evidence-1","source":"adherence.set_completion",
          "source_ids":["1"],"window":{"start":"2026-11-13","end":"2026-11-13"},
          "value":{"numerator":3,"denominator":4,"ratio":0.75},
          "unit":null,"n":4,"comparability":"comparable","gate":"signal",
          "quality_flags":[],"method_versions":{},"calibration_ids":[],
          "limitations":["prescription adherence is descriptive; it is not a training outcome"],
          "rule_ids":["DEC-AFC-01"],"assumption_ids":[]
        }]
      }
    }
    """#

    private static let unavailableJSON = #"""
    {"summary":{"workout_id":"workout-2","status":"completed",
      "adherence":{"status":"unavailable","reason":"no_prescription_snapshot",
        "original":null,"final_plan":null,
        "changes":{"swapped":[],"added":[],"removed":[],"set_count_changed":[],"targets_changed":[]},
        "quality":{}}}}
    """#
}
