import Foundation
import XCTest

@testable import StrengthApp

final class StubTransport: HTTPTransport {
    var handler: (URLRequest) throws -> (Int, Data)
    private(set) var requests: [URLRequest] = []

    init(handler: @escaping (URLRequest) throws -> (Int, Data)) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, data) = try handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }
}

final class AsyncStubTransport: HTTPTransport {
    var handler: (URLRequest) async throws -> (Int, Data)
    private(set) var requests: [URLRequest] = []

    init(handler: @escaping (URLRequest) async throws -> (Int, Data)) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, data) = try await handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }
}

final class InMemoryTokenStore: TokenStoring {
    var token: String?

    init(token: String? = nil) {
        self.token = token
    }

    func save(_ token: String) throws {
        self.token = token
    }

    func load() -> String? {
        token
    }

    func delete() {
        token = nil
    }
}


final class FakeHealthKitReadinessProvider: HealthKitReadinessProviding {
    var isAvailable = true
    var authorizationRequests = 0
    var selection = HealthKitReadinessSelection(hrv: nil, rhr: nil, staleFields: [])
    var error: Error?

    func requestAuthorization() async throws {
        authorizationRequests += 1
        if let error { throw error }
    }

    func selectSamples(serverDate: String, now: Date) async throws -> HealthKitReadinessSelection {
        if let error { throw error }
        return selection
    }
}

enum Fixtures {
    static let bootstrap = #"""
    {
      "api_version": "1",
      "server_date": "2026-11-07",
      "server_time": "2026-11-07T16:00:00+00:00",
      "utc_offset_minutes": 0,
      "server_timezone": "GMT",
      "capabilities": {
        "readiness": true,
        "prescription": false,
        "workout_write": false,
        "healthkit": false,
        "offline": false
      }
    }
    """#

    static let today = #"""
    {
      "date": "2026-11-07",
      "readiness": {
        "on_date": "2026-11-07",
        "known": true,
        "score": {
          "on_date": "2026-11-07",
          "status": "ready",
          "score": 0.82,
          "basis": "5 core fields",
          "components": [
            {"field": "sleep", "value": 4, "normalised": 0.75, "weight": 1}
          ],
          "overrides": {
            "global": {"scope": "global", "value": 0.9, "reason": "felt good"}
          },
          "category_scores": {"squat": 0.82},
          "category_factors": {"squat": {"factor": 0.95, "rir_bump": 1}},
          "context_flags": ["travel"],
          "device_suppressed": false
        },
        "context_flags": ["travel"]
      },
      "readiness_score": {
        "on_date": "2026-11-07",
        "status": "ready",
        "score": 0.82,
        "basis": "5 core fields",
        "components": [],
        "overrides": {
          "global": {"scope": "global", "value": 0.9, "reason": "felt good"}
        },
        "category_scores": {"squat": 0.82},
        "category_factors": {"squat": {"factor": 0.95, "rir_bump": 1}},
        "context_flags": ["travel"],
        "device_suppressed": false
      },
      "active_workout": null
    }
    """#

    static let history = #"""
    {
      "total": 2,
      "limit": 50,
      "offset": 0,
      "sessions": [
        {
          "session_id": "s2",
          "occurred_on": "2026-11-06",
          "session_type": "squat",
          "workout_label": "Squat",
          "set_count": 12,
          "working_set_count": 9,
          "tonnage_kg": 3450.5,
          "main_lifts": ["Competition Squat"],
          "needs_review": 0,
          "marks": 0
        },
        {
          "session_id": "s1",
          "occurred_on": "2026-11-04",
          "session_type": "hinge",
          "workout_label": "Hinge",
          "set_count": 10,
          "working_set_count": 8,
          "tonnage_kg": 4200.0,
          "main_lifts": ["Competition Deadlift"],
          "needs_review": 1,
          "marks": 2
        }
      ]
    }
    """#

    static let pair = #"""
    {
      "api_version": "1",
      "device": {"device_id": "device-1", "label": "iPhone"},
      "token": "token-abc",
      "server_date": "2026-11-07",
      "server_time": "2026-11-07T16:00:00+00:00",
      "utc_offset_minutes": 0,
      "server_timezone": "GMT"
    }
    """#

    static let bootstrapPhase2 = #"""
    {
      "api_version": "1",
      "server_date": "2026-11-07",
      "server_time": "2026-11-07T16:00:00+00:00",
      "utc_offset_minutes": 0,
      "server_timezone": "GMT",
      "capabilities": {
        "readiness": true,
        "readiness_write": true,
        "prescription": true,
        "workout_write": true,
        "healthkit": false,
        "healthkit_readiness": true,
        "offline": false
      }
    }
    """#

    static let readinessWrite = #"""
    {
      "on_date": "2026-11-07",
      "known": true,
      "score": {
        "on_date": "2026-11-07",
        "status": "ready",
        "score": 0.82,
        "basis": "weighted subjective core",
        "overrides": {},
        "context_flags": []
      }
    }
    """#

    static let issuedPlan = #"""
    {
      "issued_plan_id": "plan-1",
      "prescription_id": "prescription-1",
      "for_date": "2026-11-07",
      "session_type": "squat",
      "expires_at": "2026-11-07T17:00:00+00:00",
      "plan": {
        "for_date": "2026-11-07",
        "session_type": "squat",
        "session_label": "Squat",
        "items": [
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
            "refs": ["PRG-RIR-001"]
          }
        ],
        "warnings": [],
        "issues": []
      },
      "readiness": {
        "status": "ready",
        "score": 0.82,
        "basis": "weighted subjective core",
        "overrides": {},
        "context_flags": []
      },
      "warnings": []
    }
    """#

    static let workoutInProgress = #"""
    {
      "workout_id": "workout-1",
      "prescription_id": "prescription-1",
      "for_date": "2026-11-07",
      "session_type": "squat",
      "status": "in_progress",
      "plan": {
        "for_date": "2026-11-07",
        "session_type": "squat",
        "items": [
          {"order_index": 0, "exercise_id": "competition_squat", "sets": 3,
           "reps_low": 3, "reps_high": 5, "load_kg": 140.0, "rir_target": 2}
        ]
      },
      "sets": [],
      "forms": [],
      "elapsed_seconds": 600,
      "started_at": "2026-11-07T16:00:00+00:00"
    }
    """#

    static let workoutWithSet = #"""
    {
      "workout_id": "workout-1",
      "prescription_id": "prescription-1",
      "for_date": "2026-11-07",
      "session_type": "squat",
      "status": "in_progress",
      "plan": {
        "for_date": "2026-11-07",
        "session_type": "squat",
        "items": [
          {"order_index": 0, "exercise_id": "competition_squat", "sets": 3,
           "reps_low": 3, "reps_high": 5, "load_kg": 140.0, "rir_target": 2}
        ]
      },
      "sets": [
        {"set_id": 1, "exercise_id": "competition_squat", "set_index": 1,
         "load_kg": 140.0, "reps": 3, "rir": 2, "velocity": 0.62, "source": "manual"}
      ],
      "forms": [
        {"form_id": 1, "workout_id": "workout-1", "exercise_id": "competition_squat",
         "rating": 4, "note": null}
      ],
      "elapsed_seconds": 660,
      "started_at": "2026-11-07T16:00:00+00:00"
    }
    """#

    static let workoutCompleted = #"""
    {
      "workout_id": "workout-1",
      "prescription_id": "prescription-1",
      "for_date": "2026-11-07",
      "session_type": "squat",
      "status": "completed",
      "plan": {
        "for_date": "2026-11-07",
        "session_type": "squat",
        "items": [
          {"order_index": 0, "exercise_id": "competition_squat", "sets": 3,
           "reps_low": 3, "reps_high": 5, "load_kg": 140.0, "rir_target": 2}
        ]
      },
      "sets": [
        {"set_id": 1, "exercise_id": "competition_squat", "set_index": 1,
         "load_kg": 140.0, "reps": 3, "rir": 2, "velocity": 0.62, "source": "manual"}
      ],
      "forms": [],
      "elapsed_seconds": 2700,
      "session_rpe": 7.0,
      "started_at": "2026-11-07T16:00:00+00:00"
    }
    """#

    static let progress = #"""
    {
      "on_date": "2026-11-07",
      "coverage": {"sessions": 2, "with_srpe": 1, "pct": 50.0},
      "performance": {"points": [], "latest": null, "median_ratio": null, "n": 0},
      "volume": [{"pattern": "squat", "average": 4.0, "status": "under", "mrv": 14.0}],
      "back": {"level": null, "date": null},
      "attendance": {"weeks": 8, "from": "2026-09-12", "to": "2026-11-07",
                     "completed": 2, "target": null, "pct": null,
                     "note": "descriptive attendance"},
      "note": "Descriptive monitoring only; no prescription change."
    }
    """#

    static let serverError = #"""
    {
      "error": "readiness is not score-ready; acknowledge starting without a score",
      "code": "readiness_required",
      "details": {
        "status": "unknown",
        "score": null,
        "basis": "no readiness entry",
        "can_acknowledge": true
      }
    }
    """#
}
