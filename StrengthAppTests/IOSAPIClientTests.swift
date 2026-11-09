import XCTest

@testable import StrengthApp
import StrengthCore

@MainActor
final class IOSAPIClientTests: XCTestCase {
    private let session = IOSSession(
        baseURL: URL(string: "http://127.0.0.1:8000")!,
        token: "token-abc"
    )

    private func makeClient(
        _ handler: @escaping (URLRequest) throws -> (Int, Data)
    ) -> (IOSAPIClient, StubTransport) {
        let transport = StubTransport(handler: handler)
        return (IOSAPIClient(transport: transport), transport)
    }

    // MARK: Decoding

    func testBootstrapDecodesAndSendsTheBearerToken() async throws {
        let (client, transport) = makeClient { _ in (200, Data(Fixtures.bootstrap.utf8)) }
        let bootstrap = try await client.bootstrap(session: session)

        XCTAssertEqual(bootstrap.apiVersion, "1")
        XCTAssertEqual(bootstrap.serverDate, "2026-11-07")
        XCTAssertEqual(bootstrap.serverTime, "2026-11-07T16:00:00+00:00")
        XCTAssertEqual(bootstrap.utcOffsetMinutes, 0)
        XCTAssertEqual(bootstrap.serverTimezone, "GMT")
        XCTAssertEqual(
            bootstrap.capabilities,
            Capabilities(
                readiness: true,
                prescription: false,
                workoutWrite: false,
                healthkit: false,
                offline: false
            )
        )

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/ios/v1/bootstrap")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer token-abc"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testTodayDecodesTheReadinessScoreAndNullWorkout() async throws {
        let (client, _) = makeClient { _ in (200, Data(Fixtures.today.utf8)) }
        let today = try await client.today(session: session)

        XCTAssertEqual(today.date, "2026-11-07")
        XCTAssertNil(today.activeWorkout)
        let score = try XCTUnwrap(today.readinessScore)
        XCTAssertEqual(score.status, "ready")
        XCTAssertEqual(score.score ?? 0, 0.82, accuracy: 0.0001)
        XCTAssertEqual(score.basis, "5 core fields")
        XCTAssertEqual(score.overrides?["global"]?.value ?? 0, 0.9, accuracy: 0.0001)
        XCTAssertEqual(score.overrides?["global"]?.reason, "felt good")
        XCTAssertEqual(score.contextFlags, ["travel"])
        XCTAssertEqual(score.categoryFactors?["squat"]?.rirBump, 1)
        XCTAssertEqual(today.readiness?.score?.status, "ready")
    }

    func testTodayDecodesAnActiveWorkoutSummary() async throws {
        let body = Fixtures.today.replacingOccurrences(
            of: "\"active_workout\": null",
            with: #"""
            "active_workout": {
              "workout_id": "workout-1",
              "for_date": "2026-11-07",
              "session_type": "squat",
              "status": "in_progress",
              "started_at": "2026-11-07T17:00:00+00:00",
              "plan": {"items": []},
              "sets": []
            }
            """#
        )
        let (client, _) = makeClient { _ in (200, Data(body.utf8)) }
        let today = try await client.today(session: session)
        let workout = try XCTUnwrap(today.activeWorkout)
        XCTAssertEqual(workout.workoutId, "workout-1")
        XCTAssertEqual(workout.sessionType, "squat")
        XCTAssertEqual(workout.status, "in_progress")
    }

    func testHistoryDecodesAndSendsPaging() async throws {
        let (client, transport) = makeClient { _ in (200, Data(Fixtures.history.utf8)) }
        let history = try await client.history(session: session, limit: 10, offset: 5)

        XCTAssertEqual(history.total, 2)
        XCTAssertEqual(history.limit, 50)
        XCTAssertEqual(history.offset, 0)
        XCTAssertEqual(history.sessions.count, 2)
        XCTAssertEqual(history.sessions[0].sessionId, "s2")
        XCTAssertEqual(history.sessions[0].setCount, 12)
        XCTAssertEqual(history.sessions[1].mainLifts, ["Competition Deadlift"])
        XCTAssertEqual(history.sessions[1].needsReview, 1)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/api/ios/v1/history")
        XCTAssertEqual(request.url?.query, "limit=10&offset=5")
    }

    func testPairPostsTheNormalizedCodeAndLabel() async throws {
        let (client, transport) = makeClient { _ in (200, Data(Fixtures.pair.utf8)) }
        let response = try await client.pair(
            baseURL: try IOSAPIClient.validatedBaseURL("http://127.0.0.1:8000"),
            code: "1234 5678",
            label: "  Gym iPhone  "
        )

        XCTAssertEqual(response.token, "token-abc")
        XCTAssertEqual(response.device.deviceId, "device-1")
        XCTAssertEqual(response.device.label, "iPhone")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/ios/v1/pair")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/json"
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try JSONDecoder().decode(
            [String: String].self,
            from: XCTUnwrap(request.httpBody)
        )
        XCTAssertEqual(body, ["code": "12345678", "label": "Gym iPhone"])
    }

    // MARK: Errors

    func test401And403MapToAuthFailures() async {
        for status in [401, 403] {
            let (client, _) = makeClient { _ in (status, Data()) }
            do {
                _ = try await client.bootstrap(session: session)
                XCTFail("expected an auth failure for \(status)")
            } catch let error as APIError {
                XCTAssertTrue(error.isAuthenticationFailure)
                if status == 401 {
                    XCTAssertEqual(error, .unauthorized)
                } else {
                    XCTAssertEqual(error, .forbidden)
                }
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testValidationEnvelopeIsKeptFor400() async {
        let body = #"{"error":"pairing code must be 8 digits","fields":{"code":"must be 8 digits"}}"#
        let (client, _) = makeClient { _ in (400, Data(body.utf8)) }
        do {
            _ = try await client.pair(
                baseURL: try IOSAPIClient.validatedBaseURL("http://127.0.0.1:8000"),
                code: "12345678",
                label: "iPhone"
            )
            XCTFail("expected a validation error")
        } catch let error as APIError {
            guard case .http(let status, let message, let fields) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(status, 400)
            XCTAssertEqual(message, "pairing code must be 8 digits")
            XCTAssertEqual(fields["code"], "must be 8 digits")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test500UsesTheGenericClientMessage() async {
        let body = #"{"error":"traceback with a local path"}"#
        let (client, _) = makeClient { _ in (500, Data(body.utf8)) }
        do {
            _ = try await client.bootstrap(session: session)
            XCTFail("expected a server error")
        } catch let error as APIError {
            XCTAssertEqual(
                error.errorDescription,
                "The server could not complete the request (HTTP 500)."
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: Retries

    func testGETRetriesTransientTransportErrorsTwice() async throws {
        var calls = 0
        let (client, _) = makeClient { _ in
            calls += 1
            if calls < 3 {
                throw URLError(.timedOut)
            }
            return (200, Data(Fixtures.bootstrap.utf8))
        }
        let bootstrap = try await client.bootstrap(session: session)
        XCTAssertEqual(bootstrap.apiVersion, "1")
        XCTAssertEqual(calls, 3)
    }

    func testGETStopsAfterBoundedRetries() async {
        var calls = 0
        let (client, _) = makeClient { _ in
            calls += 1
            throw URLError(.cannotConnectToHost)
        }
        do {
            _ = try await client.bootstrap(session: session)
            XCTFail("expected a transport error")
        } catch let error as APIError {
            guard case .transport = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(calls, 3)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testPairDoesNotRetry() async {
        var calls = 0
        let (client, _) = makeClient { _ in
            calls += 1
            throw URLError(.timedOut)
        }
        do {
            _ = try await client.pair(
                baseURL: try IOSAPIClient.validatedBaseURL("http://127.0.0.1:8000"),
                code: "12345678",
                label: "iPhone"
            )
            XCTFail("expected a transport error")
        } catch {
            XCTAssertEqual(calls, 1)
        }
    }

    // MARK: Input validation

    func testBaseURLValidation() throws {
        XCTAssertEqual(
            try IOSAPIClient.validatedBaseURL("http://127.0.0.1:8000/").absoluteString,
            "http://127.0.0.1:8000"
        )
        XCTAssertEqual(
            try IOSAPIClient.validatedBaseURL("http://127.0.0.1:8000").absoluteString,
            "http://127.0.0.1:8000"
        )
        XCTAssertEqual(
            try IOSAPIClient.validatedBaseURL(" https://gym.local:8443 ").absoluteString,
            "https://gym.local:8443"
        )
        for invalid in [
            "",
            "not a url",
            "ftp://127.0.0.1:8000",
            "http:///missing-host",
            "http://user:pass@127.0.0.1:8000",
            "http://127.0.0.1:8000/?x=1",
        ] {
            XCTAssertThrowsError(try IOSAPIClient.validatedBaseURL(invalid)) { error in
                guard case APIError.invalidBaseURL = error else {
                    return XCTFail("unexpected error for \(invalid): \(error)")
                }
            }
        }
    }

    func testPairingCodeNormalization() throws {
        XCTAssertEqual(try IOSAPIClient.normalizeCode("1234 5678"), "12345678")
        XCTAssertEqual(try IOSAPIClient.normalizeCode("1234-5678"), "12345678")
        XCTAssertEqual(try IOSAPIClient.normalizeCode(" 12345678 "), "12345678")
        for invalid in ["", "1234567", "123456789", "abcdefgh", "１２３４５６７８"] {
            XCTAssertThrowsError(try IOSAPIClient.normalizeCode(invalid))
        }
    }

    func testLabelNormalization() throws {
        XCTAssertEqual(try IOSAPIClient.normalizeLabel(""), "iPhone")
        XCTAssertEqual(try IOSAPIClient.normalizeLabel("  Gym  "), "Gym")
        XCTAssertThrowsError(try IOSAPIClient.normalizeLabel(String(repeating: "x", count: 41)))
    }
}
