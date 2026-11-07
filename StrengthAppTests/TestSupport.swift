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
}
