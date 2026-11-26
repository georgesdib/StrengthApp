import XCTest

@testable import StrengthApp
import StrengthCore

@MainActor
final class OfflineExecutionContractTests: XCTestCase {
    private let session = IOSSession(
        baseURL: URL(string: "http://127.0.0.1:8000")!,
        token: "token-abc",
        deviceID: "phone-1"
    )

    private func makeClient(
        _ handler: @escaping (URLRequest) throws -> (Int, Data)
    ) -> (IOSAPIClient, StubTransport) {
        let transport = StubTransport(handler: handler)
        return (IOSAPIClient(transport: transport), transport)
    }

    // MARK: C1 — settings

    func testTechniqueThrottleIsEncodedInThePrescriptionSettings() async throws {
        let (client, transport) = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/ios/v1/prescriptions")
            let object = request.httpBody.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            let settings = object?["settings"] as? [String: Any]
            XCTAssertEqual(settings?["technique_throttle"] as? Bool, true)
            return (202, Data("""
            {"issued_plan_id":"plan-1","execution_id":"exec-1","status":"queued",
             "for_date":"2026-11-23","request_expires_at":"2026-11-23T12:00:00Z"}
            """.utf8))
        }
        let ack = try await client.issuePrescription(
            IssuePrescriptionRequest(
                readinessAck: true,
                confirmations: nil,
                settings: PlanSettings(techniqueThrottle: true)
            ),
            session: session,
            idempotencyKey: "issue-1"
        )
        XCTAssertEqual(ack.executionId, "exec-1")
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testPlanStateDecodesExecutionIDAndLoadCatalogue() throws {
        let json = """
        {"status":"ready","issued_plan_id":"plan-1","execution_id":"exec-1",
         "for_date":"2026-11-23","settings":{"technique_throttle":true},
         "plan":{"for_date":"2026-11-23","session_type":"squat","session_label":"Squat",
                 "items":[{"order_index":0,"exercise_id":"competition_squat","sets":3,
                           "reps_low":5,"reps_high":5,"load_kg":140,"load_basis":"external",
                           "rir_target":2,"effort_model":"rir","rest_s":180,"essential":true,
                           "refs":["MOD-TECH-001"]}]},
         "load_catalogue":{"catalogue_version":"load-catalogue/v1","as_of":"2026-11-23",
           "exercises":{"competition_squat":{"load_source":"e1rm","base_load_kg":163.3,
             "accessory_load_kg":140.0,"increment_kg":0.5,"bodyweight":false,"power":false}}}}
        """
        let state = try JSONDecoder.withSnakeCase.decode(
            PlansStateResponse.self, from: Data(json.utf8)
        )
        XCTAssertEqual(state.executionId, "exec-1")
        XCTAssertEqual(state.issuedPlan?.executionID, "exec-1")
        XCTAssertEqual(state.loadCatalogue?.version, "load-catalogue/v1")
        XCTAssertEqual(state.issuedPlan?.loadCatalogue?.entry(for: "competition_squat")?.incrementKg, Decimal(string: "0.5"))
        XCTAssertEqual(state.issuedPlan?.techniqueThrottleInForce, true)
        XCTAssertEqual(state.issuedPlan?.techniqueThrottledItems.count, 1)
    }

    // MARK: C1 — start body

    func testStartSendsExecutionIDAndStartedAt() async throws {
        let (client, transport) = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/ios/v1/workouts")
            let object = request.httpBody.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            XCTAssertEqual(object?["issued_plan_id"] as? String, "plan-1")
            XCTAssertEqual(object?["execution_id"] as? String, "exec-1")
            XCTAssertEqual(object?["started_at"] as? String, "2026-11-23T10:00:00Z")
            return (200, Data(Fixtures.workoutInProgress.utf8))
        }
        _ = try await client.startWorkout(
            issuedPlanId: "plan-1",
            executionId: "exec-1",
            startedAt: "2026-11-23T10:00:00Z",
            session: session,
            idempotencyKey: "start-1"
        )
        XCTAssertEqual(transport.requests.count, 1)
    }

    // MARK: C1 — catalogue prefill

    private func catalogue(base: Decimal, accessory: Decimal? = nil) -> LoadCatalogue {
        LoadCatalogue(
            catalogueVersion: "load-catalogue/v1",
            asOf: "2026-11-23",
            exercises: [
                "competition_squat": LoadCatalogueEntry(
                    loadSource: "e1rm", baseLoadKg: base,
                    accessoryLoadKg: accessory, incrementKg: Decimal(string: "0.5"),
                    bodyweight: false, power: false
                ),
                "barbell_curl": LoadCatalogueEntry(
                    loadSource: "double_progression", baseLoadKg: nil,
                    accessoryLoadKg: accessory, incrementKg: Decimal(string: "0.5"),
                    bodyweight: false, power: false
                ),
                "pull_up": LoadCatalogueEntry(
                    loadSource: "bodyweight", baseLoadKg: nil,
                    accessoryLoadKg: nil, incrementKg: 0.5,
                    bodyweight: true, power: false
                ),
                "box_jump": LoadCatalogueEntry(
                    loadSource: "power", baseLoadKg: nil,
                    accessoryLoadKg: nil, incrementKg: 0.5,
                    bodyweight: false, power: true
                ),
                "cold_lift": LoadCatalogueEntry(
                    loadSource: "e1rm", baseLoadKg: nil,
                    accessoryLoadKg: nil, incrementKg: 0.5,
                    bodyweight: false, power: false
                )
            ]
        )
    }

    func testCataloguePrefillMatchesTheDocumentedTail() {
        let built = catalogue(
            base: Decimal(string: "163.3")!,
            accessory: Decimal(string: "140")!
        )
        // 163.3 / (1 + (5 + 2)/30) = 132.13… -> 132.0 at 0.5 kg.
        XCTAssertEqual(
            built.prefill(exerciseId: "competition_squat", essential: true, reps: 5, rir: 2).loadKg,
            132.0
        )
        // Missing RIR falls back to plain Epley: 163.3 / (1 + 5/30) = 139.97… -> 139.5.
        XCTAssertEqual(
            built.prefill(exerciseId: "competition_squat", essential: true, reps: 5, rir: nil).loadKg,
            139.5
        )
        // Accessory holds the working load, rounded down to its increment.
        XCTAssertEqual(
            built.prefill(exerciseId: "barbell_curl", essential: false, reps: 10, rir: 2).loadKg,
            140.0
        )
        XCTAssertEqual(
            built.prefill(exerciseId: "pull_up", essential: true, reps: 8, rir: 2).loadKg,
            0
        )
        XCTAssertNil(
            built.prefill(exerciseId: "box_jump", essential: true, reps: 3, rir: 2).loadKg
        )
        XCTAssertEqual(
            built.prefill(exerciseId: "cold_lift", essential: true, reps: 5, rir: 2).reason,
            "no_catalogue_base"
        )
    }

    func testCataloguePrefillLandsExactlyOnAnIncrement() {
        let built = catalogue(
            base: Decimal(string: "82.5")!,
            accessory: Decimal(string: "82.5")!
        )
        // No reps/RIR: the divisor is 1, so this is the boundary case that a binary Double
        // implementation tends to round to 82.0.
        XCTAssertEqual(
            built.prefill(exerciseId: "competition_squat", essential: true, reps: 0, rir: 0).loadKg,
            82.5
        )
        XCTAssertEqual(
            built.prefill(exerciseId: "barbell_curl", essential: false, reps: 10, rir: 2).loadKg,
            82.5
        )
    }

    func testExecutionChangeSendsTheClientPrefill() async throws {
        let (client, transport) = makeClient { request in
            let object = request.httpBody.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            XCTAssertEqual(object?["prefill_load_kg"] as? Double, 132.0)
            XCTAssertEqual(object?["prefill_catalogue_version"] as? String, "load-catalogue/v1")
            XCTAssertEqual(object?["prefill_as_of"] as? String, "2026-11-23")
            XCTAssertNil(object?["prefill_requested"])
            return (200, Data("""
            {"execution":{"workout_id":"workout-1","watermark":1,"substitutions":[
              {"event_id":1,"kind":"substitution","plan_item_index":0,
               "exercise_id":"competition_squat","prefill_load_kg":132.0,
               "prefill_reason":"client_applied","prefill_verified":false,
               "prefill_expected_load_kg":132.5,"prefill_mismatch_reason":"value_differs"}],
              "additions":[]}}
            """.utf8))
        }
        let response = try await client.recordExecutionChange(
            workoutId: "workout-1",
            body: ExecutionChangeRequest(
                eventId: "event-1",
                change: "substitution",
                planItemIndex: 0,
                exerciseId: "competition_squat",
                prefillLoadKg: 132.0,
                prefillCatalogueVersion: "load-catalogue/v1",
                prefillAsOf: "2026-11-23"
            ),
            session: session,
            idempotencyKey: "exec-1"
        )
        let change = response.execution.substitutions.first
        XCTAssertEqual(change?.prefillVerified, false)
        XCTAssertEqual(change?.prefillExpectedLoadKg, 132.5)
        XCTAssertEqual(transport.requests.count, 1)
    }

    // MARK: C1/C2 — finish and summary

    func testCompleteSendsPendingDevices() async throws {
        let (client, transport) = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/ios/v1/workouts/workout-1/complete")
            let object = request.httpBody.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            XCTAssertEqual(object?["pending_devices"] as? [String], ["watch-1"])
            return (200, Data(Fixtures.workoutInProgress.utf8))
        }
        _ = try await client.completeWorkout(
            workoutId: "workout-1",
            body: CompleteWorkoutRequest(
                sessionRpe: 8, notRecorded: false, durationMin: nil, notes: nil,
                pendingDevices: ["watch-1"]
            ),
            session: session,
            idempotencyKey: "finish-1"
        )
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testSummaryDecodesOpenReconciliation() throws {
        let json = """
        {"summary":{"workout_id":"workout-1","status":"completed",
          "reconciliation":{"state":"open","pending_devices":["watch-1"],
                            "closes_at":"2026-11-30T10:00:00Z"}}}
        """
        let envelope = try JSONDecoder.withSnakeCase.decode(
            WorkoutSummaryEnvelope.self, from: Data(json.utf8)
        )
        XCTAssertEqual(envelope.summary.reconciliation?.isOpen, true)
        XCTAssertEqual(envelope.summary.reconciliation?.pendingDevices, ["watch-1"])
    }

    func testReconciliationDevicePost() async throws {
        let (client, transport) = makeClient { request in
            XCTAssertEqual(
                request.url?.path,
                "/api/ios/v1/workouts/workout-1/reconciliation"
            )
            let object = request.httpBody.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            XCTAssertEqual(object?["device_id"] as? String, "watch-1")
            return (200, Data("""
            {"reconciliation":{"state":"closed","pending_devices":[],"closes_at":null}}
            """.utf8))
        }
        let response = try await client.reconcileDevice(
            workoutId: "workout-1", deviceId: "watch-1",
            session: session, idempotencyKey: "reconcile-1"
        )
        XCTAssertEqual(response.reconciliation.state, "closed")
        XCTAssertEqual(transport.requests.count, 1)
    }
}

private extension JSONDecoder {
    static var withSnakeCase: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
