import XCTest
@testable import StrengthApp
import StrengthCore

private final class RecordingRelay: WatchRelayTransport {
    var requests: [WatchRelayRequest] = []
    var response: WatchRelayResponse?

    func send(_ request: WatchRelayRequest) async throws -> WatchRelayResponse {
        requests.append(request)
        guard let response else { throw APIError.transport("no relay response") }
        return response
    }
}

@MainActor
final class WatchRelayTests: XCTestCase {
    func testTransportFailureFallsBackToThePhoneWithTheWatchToken() async throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let workout = try decoder.decode(
            WorkoutDetail.self, from: Data(Fixtures.workoutWithSet.utf8)
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let payload = try encoder.encode(workout)

        let relay = RecordingRelay()
        relay.response = WatchRelayResponse(
            requestId: "request-1", ok: true, payload: payload
        )
        let transport = StubTransport { _ in throw APIError.transport("offline") }
        let client = IOSAPIClient(transport: transport)
        client.relay = relay
        let session = IOSSession(
            baseURL: URL(string: "http://home.local:8000")!,
            token: "watch-token",
            deviceID: "watch-1"
        )

        let started = try await client.startWorkout(
            issuedPlanId: "plan-1",
            session: session,
            idempotencyKey: "start-key"
        )
        XCTAssertEqual(started.workoutId, workout.workoutId)
        let request = try XCTUnwrap(relay.requests.first)
        XCTAssertEqual(request.operation, .start)
        XCTAssertEqual(request.token, "watch-token")
        XCTAssertEqual(request.deviceID, "watch-1")
        XCTAssertEqual(request.idempotencyKey, "start-key")
        XCTAssertEqual(request.issuedPlanId, "plan-1")
    }

    func testDirectSuccessDoesNotUseTheRelay() async throws {
        let relay = RecordingRelay()
        let transport = StubTransport { _ in
            (200, Data(Fixtures.workoutWithSet.utf8))
        }
        let client = IOSAPIClient(transport: transport)
        client.relay = relay
        let session = IOSSession(
            baseURL: URL(string: "http://home.local:8000")!,
            token: "watch-token"
        )
        _ = try await client.startWorkout(
            issuedPlanId: "plan-1", session: session, idempotencyKey: "start-key"
        )
        XCTAssertTrue(relay.requests.isEmpty)
    }
}

