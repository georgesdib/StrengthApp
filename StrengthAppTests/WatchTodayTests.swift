import XCTest
@testable import StrengthApp
import StrengthCore

@MainActor
final class WatchTodayTests: XCTestCase {
    private func planState(
        status: String = "ready",
        target: String? = "watch",
        withPlan: Bool = true,
        elapsed: Int? = nil,
        readiness: [String: Any]? = nil
    ) throws -> PlansStateResponse {
        var object: [String: Any] = [
            "status": status,
            "issued_plan_id": "plan-1",
            "for_date": "2026-11-10",
            "plan_expires_at": "2026-11-10T20:00:00+00:00",
            "execution_target": target ?? NSNull(),
            "session_type": "lower",
            "warnings": ["Keep the bar path quiet."],
        ]
        if let elapsed {
            object["elapsed_seconds"] = elapsed
        }
        if let readiness {
            object["readiness"] = readiness
        }
        if withPlan {
            object["plan"] = [
                "for_date": "2026-11-10",
                "session_type": "lower",
                "session_label": "Lower",
                "items": [[
                    "order_index": 0,
                    "exercise_id": "back_squat",
                    "sets": 3,
                    "reps_low": 5,
                    "reps_high": 5,
                    "load_kg": 100.0,
                    "load_basis": "percent",
                    "rir_target": 2,
                    "effort_model": "rir",
                    "refs": [],
                    "rest_s": 180,
                    "essential": true,
                    "warmup": [
                        ["percent": 40, "reps": 5, "load_kg": 40],
                        ["percent": 60, "reps": 3, "load_kg": 60]
                    ],
                ]],
                "warnings": [],
                "issues": [],
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PlansStateResponse.self, from: data)
    }

    func testReadyWatchPlanMapsToAReadOnlySummary() throws {
        let state = WatchTodayMapper.map(try planState())
        guard case .ready(let plan) = state else {
            return XCTFail("Expected a ready plan")
        }
        XCTAssertEqual(plan.issuedPlanID, "plan-1")
        XCTAssertEqual(plan.sessionType, "lower")
        XCTAssertEqual(plan.items.count, 1)
        XCTAssertEqual(plan.items[0].exerciseLabel, "Back Squat")
        XCTAssertEqual(plan.items[0].setsLabel, "3")
        XCTAssertEqual(plan.items[0].repsLabel, "5")
        XCTAssertEqual(plan.items[0].loadLabel, "100.0 kg")
        XCTAssertEqual(plan.items[0].effortLabel, "RIR 2")
        XCTAssertEqual(plan.items[0].restLabel, "180s rest")
        XCTAssertEqual(plan.items[0].warmupLabel, "40.0 kg×5 · 60.0 kg×3")
        XCTAssertEqual(plan.warnings, ["Keep the bar path quiet."])
    }

    func testUnknownLoadIsNotRenderedAsBodyweight() {
        let unknown = PrescriptionItem(
            orderIndex: 0,
            exerciseId: "trap_bar_deadlift",
            sets: 3,
            repsLow: 5,
            repsHigh: 5,
            loadKg: nil,
            loadBasis: nil,
            unknownLoadReason: "swapped during workout; load not re-solved",
            rirTarget: 2,
            effortModel: "rir",
            refs: [],
            restS: 180,
            essential: false
        )
        XCTAssertEqual(unknown.loadLabel, "Load not set")

        let bodyweight = PrescriptionItem(
            orderIndex: 1,
            exerciseId: "pull_up",
            sets: 3,
            repsLow: 5,
            repsHigh: 5,
            loadKg: 0,
            loadBasis: "bodyweight",
            rirTarget: 2,
            effortModel: "rir",
            refs: [],
            restS: 120,
            essential: false
        )
        XCTAssertEqual(bodyweight.loadLabel, "bodyweight")
    }

    func testTimeBasedExerciseUsesSeconds() {
        let item = PrescriptionItem(
            orderIndex: 0,
            exerciseId: "plank",
            sets: 3,
            repsLow: 30,
            repsHigh: 30,
            repsUnit: "seconds",
            loadKg: 0,
            loadBasis: "bodyweight",
            rirTarget: 2,
            effortModel: "rir",
            refs: [],
            restS: 60,
            essential: false
        )
        XCTAssertEqual(item.repsLabel, "30s")
        XCTAssertTrue(item.isTimeBased)
    }

    func testNoPlanAndBuildingStates() throws {
        XCTAssertEqual(
            WatchTodayMapper.map(try planState(status: "none", withPlan: false)),
            .noPlan
        )
        XCTAssertEqual(
            WatchTodayMapper.map(try planState(status: "building", withPlan: false, elapsed: 12)),
            .generating(elapsedSeconds: 12)
        )
    }

    func testServiceFetchesBootstrapAndPlanFromTheGivenSession() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer watch-token")
            XCTAssertEqual(request.url?.host, "home.local")
            switch request.url?.path {
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrapPhase2.utf8))
            case "/api/ios/v1/plans/current":
                return (200, Data(self.planJSON().utf8))
            case "/api/ios/v1/today":
                return (200, Data(#"{"date":"2026-11-10"}"#.utf8))
            default:
                return (404, Data())
            }
        }
        let service = WatchTodayService(client: IOSAPIClient(transport: transport))
        let snapshot = try await service.fetch(session: IOSSession(
            baseURL: URL(string: "http://home.local:8000")!,
            token: "watch-token",
            deviceID: "watch-1"
        ))
        guard case .ready(let plan) = snapshot.state else {
            return XCTFail("Expected a ready plan")
        }
        XCTAssertEqual(plan.issuedPlanID, "plan-1")
        XCTAssertNotNil(snapshot.serverDate)
        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertEqual(
            Set(transport.requests.compactMap { $0.url?.path }),
            ["/api/ios/v1/bootstrap", "/api/ios/v1/plans/current", "/api/ios/v1/today"]
        )
    }

    func testServicePropagatesAuthenticationFailure() async {
        let transport = StubTransport { request in
            (401, Data("{}".utf8))
        }
        let service = WatchTodayService(client: IOSAPIClient(transport: transport))
        do {
            _ = try await service.fetch(session: IOSSession(
                baseURL: URL(string: "http://home.local:8000")!,
                token: "watch-token",
                deviceID: "watch-1"
            ))
            XCTFail("Expected authentication failure")
        } catch let api as APIError {
            XCTAssertTrue(api.isAuthenticationFailure)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Readiness and the empty state

    func testReadinessSummaryCarriesTheServersScoreAndTwoDrivers() throws {
        let state = try planState(readiness: [
            "status": "ready",
            "score": 0.82,
            "components": [
                ["field": "hrv_ms", "value": 62, "normalised": 0.8, "weight": 0.3],
                ["field": "sleep_hours", "value": 7.4, "normalised": 0.9, "weight": 0.5],
                ["field": "rhr_bpm", "value": 48, "normalised": 0.7, "weight": 0.2],
            ],
        ])
        let summary = try XCTUnwrap(WatchReadinessSummary.make(state.readiness))
        XCTAssertEqual(summary.statusWord, "Ready")
        XCTAssertEqual(summary.scoreText, "82%")
        XCTAssertEqual(summary.drivers, ["Sleep 7.4 h", "HRV 62 ms"])
    }

    func testInsufficientReadinessSaysNotScoredYet() throws {
        let state = try planState(readiness: ["status": "insufficient"])
        let summary = try XCTUnwrap(WatchReadinessSummary.make(state.readiness))
        XCTAssertEqual(summary.statusWord, "Not scored yet")
        XCTAssertNil(summary.scoreText)
        XCTAssertTrue(summary.drivers.isEmpty)
    }

    func testReadinessSummaryIsAbsentWithoutAScore() {
        XCTAssertNil(WatchReadinessSummary.make(nil))
    }

    func testEmptyCopyAnswersWhyAndWhatNext() throws {
        XCTAssertEqual(WatchTodayCopy.empty(for: .noPlan)?.identifier, "no-plan")
        XCTAssertEqual(
            WatchTodayCopy.empty(for: .noPlan)?.action,
            "Request one on your iPhone."
        )
        XCTAssertEqual(WatchTodayCopy.empty(for: .missingCredentials)?.identifier, "unpaired")
        XCTAssertNil(WatchTodayCopy.empty(for: .loading))
        XCTAssertNil(WatchTodayCopy.empty(for: .generating(elapsedSeconds: 3)))
        XCTAssertNil(WatchTodayCopy.empty(for: WatchTodayMapper.map(try planState())))

        let offline = WatchTodayCopy.empty(for: .offline(nil, detail: "home.local — timed out"))
        XCTAssertEqual(offline?.identifier, "offline")
        XCTAssertTrue(offline?.detail?.contains("home.local") == true)
    }

    func testServiceCarriesReadinessFromTheSamePlanRead() async throws {
        let body = """
        {
          "status": "none",
          "readiness": { "status": "ready", "score": 0.64 }
        }
        """
        let transport = StubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrapPhase2.utf8))
            case "/api/ios/v1/plans/current":
                return (200, Data(body.utf8))
            default:
                return (404, Data())
            }
        }
        let service = WatchTodayService(client: IOSAPIClient(transport: transport))
        let snapshot = try await service.fetch(session: IOSSession(
            baseURL: URL(string: "http://home.local:8000")!,
            token: "watch-token",
            deviceID: "watch-1"
        ))
        XCTAssertEqual(snapshot.state, .noPlan)
        XCTAssertEqual(snapshot.readiness?.scoreText, "64%")
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testServiceUsesTodayReadinessWhenThePlanDoesNotCarryIt() async throws {
        let planBody = #"{"status":"none"}"#
        let todayBody = """
        {"date":"2026-11-23","readiness_score":{"status":"ready","score":0.73}}
        """
        let transport = StubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrapPhase2.utf8))
            case "/api/ios/v1/plans/current":
                return (200, Data(planBody.utf8))
            case "/api/ios/v1/today":
                return (200, Data(todayBody.utf8))
            default:
                return (404, Data())
            }
        }
        let service = WatchTodayService(client: IOSAPIClient(transport: transport))
        let snapshot = try await service.fetch(session: IOSSession(
            baseURL: URL(string: "http://home.local:8000")!,
            token: "watch-token",
            deviceID: "watch-1"
        ))
        XCTAssertEqual(snapshot.state, .noPlan)
        XCTAssertEqual(snapshot.readiness?.statusWord, "Ready")
        XCTAssertEqual(snapshot.readiness?.scoreText, "73%")
    }

    private func planJSON() -> String {
        """
        {
          "status": "ready",
          "issued_plan_id": "plan-1",
          "for_date": "2026-11-10",
          "plan_expires_at": "2026-11-10T20:00:00+00:00",
          "execution_target": "watch",
          "session_type": "lower",
          "warnings": [],
          "plan": {
            "for_date": "2026-11-10",
            "session_type": "lower",
            "session_label": "Lower",
            "items": [],
            "warnings": [],
            "issues": []
          }
        }
        """
    }
}
