import XCTest
@testable import StrengthApp
import StrengthCore

@MainActor
final class WatchTodayTests: XCTestCase {
    private func planState(
        status: String = "ready",
        target: String? = "watch",
        withPlan: Bool = true,
        elapsed: Int? = nil
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
        XCTAssertEqual(plan.executionTarget, "watch")
        XCTAssertEqual(plan.items.count, 1)
        XCTAssertEqual(plan.items[0].exerciseLabel, "Back Squat")
        XCTAssertEqual(plan.items[0].setsLabel, "3")
        XCTAssertEqual(plan.items[0].repsLabel, "5")
        XCTAssertEqual(plan.items[0].loadLabel, "100.0 kg")
        XCTAssertEqual(plan.items[0].effortLabel, "RIR 2")
        XCTAssertEqual(plan.items[0].restLabel, "180s rest")
        XCTAssertEqual(plan.warnings, ["Keep the bar path quiet."])
    }

    func testPhoneTargetedPlanIsHidden() throws {
        XCTAssertEqual(
            WatchTodayMapper.map(try planState(target: "phone")),
            .phonePlan
        )
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
        XCTAssertEqual(
            WatchTodayMapper.map(try planState(status: "building", target: "phone", withPlan: false)),
            .phonePlan
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
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(
            Set(transport.requests.compactMap { $0.url?.path }),
            ["/api/ios/v1/bootstrap", "/api/ios/v1/plans/current"]
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
