import XCTest
import StrengthCore

/// WP2: ordered groups and the execution view compose the rows both clients render.
final class ExecutionChangeModelTests: XCTestCase {
    private func plan() -> PrescriptionPlan {
        let json = """
        {
          "for_date": "2026-11-01",
          "session_type": "squat",
          "items": [
            {"order_index": 0, "exercise_id": "trap_bar_deadlift", "sets": 4,
             "reps_low": 3, "reps_high": 5, "load_kg": 100,
             "set_groups": [
               {"group_index": 0, "sets": 1, "load_kg": 120, "reps_low": 3,
                "reps_high": 5, "rir_target": 1},
               {"group_index": 1, "sets": 3, "load_kg": 100, "reps_low": 3,
                "reps_high": 5, "rir_target": 3}
             ]},
            {"order_index": 1, "exercise_id": "bench_press", "sets": 3,
             "reps_low": 5, "reps_high": 5, "load_kg": 90}
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(PrescriptionPlan.self, from: Data(json.utf8))
    }

    private func view() -> ExecutionView {
        let json = """
        {"workout_id": "w-1", "watermark": 7,
         "substitutions": [
           {"event_id": 5, "kind": "substitution", "plan_item_index": 0,
            "exercise_id": "competition_squat", "reps_low": 3, "reps_high": 5,
            "rir_target": 2, "prefill_load_kg": 110, "prefill_reason": "solved",
            "client_event_id": "e-1"}
         ],
         "additions": [
           {"event_id": 7, "kind": "addition", "after_item_index": 1,
            "exercise_id": "lateral_raise", "reps_low": 10, "reps_high": 12,
            "rir_target": 3, "prefill_load_kg": 12, "prefill_reason": "solved"}
         ]}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(ExecutionView.self, from: Data(json.utf8))
    }

    func testOrderedGroupsDecodeAndSelectByCumulativeSets() {
        let plan = plan()
        let first = plan.items[0]
        XCTAssertEqual(first.setGroups?.count, 2)
        XCTAssertEqual(first.setGroups?[0].rowLabel, "1 × 3-5 @ 120.0 kg · RIR 1")
        let rows = ExecutionView.empty.rows(plan: plan)
        // The plan surfaces render one row per group from this list, in order.
        XCTAssertEqual(rows[0].groups.map(\.rowLabel), [
            "1 × 3-5 @ 120.0 kg · RIR 1",
            "3 × 3-5 @ 100.0 kg · RIR 3"
        ])
        XCTAssertEqual(rows[0].group(forLoggedCount: 0)?.loadKg, 120)
        XCTAssertEqual(rows[0].group(forLoggedCount: 1)?.loadKg, 100)
        XCTAssertEqual(rows[0].group(forLoggedCount: 6)?.loadKg, 100)
        XCTAssertNil(rows[1].group(forLoggedCount: 0))
    }

    func testSubstitutionReplacesTheSlotAndAdditionFollowsItsAnchor() {
        let rows = view().rows(plan: plan())
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].kind, .substituted)
        XCTAssertEqual(rows[0].exerciseId, "competition_squat")
        XCTAssertEqual(rows[0].planItemIndex, 0)
        XCTAssertEqual(rows[0].substitutesPlanItemIndex, 0)
        XCTAssertEqual(rows[0].loadKg, 110)
        XCTAssertTrue(rows[0].groups.isEmpty)
        XCTAssertEqual(rows[1].exerciseId, "bench_press")
        XCTAssertEqual(rows[2].kind, .added)
        XCTAssertEqual(rows[2].exerciseId, "lateral_raise")
        XCTAssertNil(rows[2].planItemIndex)
        XCTAssertEqual(rows[2].afterItemIndex, 1)
    }

    func testAnAdditionWithAMissingAnchorStaysVisibleAtTheEnd() {
        let additions = [
            ExecutionChange(eventId: 9, kind: "addition", afterItemIndex: 42,
                            exerciseId: "curl", repsLow: 8, repsHigh: 10,
                            rirTarget: 2, prefillLoadKg: nil,
                            prefillReason: "authored_offline")
        ]
        let rows = ExecutionView(
            workoutId: "w-1", watermark: 9, substitutions: [], additions: additions
        ).rows(plan: plan())
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.last?.kind, .added)
        XCTAssertEqual(rows.last?.exerciseId, "curl")
    }

    func testRemotePayloadCarriesTheExecutionView() {
        let view = view()
        let payload = RemoteExecutionPayload(
            workoutId: "w-1", status: "in_progress", planRevision: 0,
            ownerDeviceId: "watch-1", plan: plan(), execution: view
        )
        let decoded = payload.encodedString().flatMap(RemoteExecutionPayload.decode)
        XCTAssertEqual(decoded?.schema, 2)
        XCTAssertEqual(decoded?.execution?.watermark, 7)
    }
}
