import XCTest
@testable import StrengthApp
import StrengthCore

@MainActor
final class WatchRelayGatewayTests: XCTestCase {
    func testPhoneExecutesTheRelayedBootstrapWithTheWatchToken() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer watch-token")
            return (200, Data(Fixtures.bootstrap.utf8))
        }
        let defaults = UserDefaults(suiteName: "WatchRelayGatewayTests-\(UUID())")!
        let coordinator = WatchPairingCoordinator(
            client: IOSAPIClient(transport: transport),
            store: PairedStore(defaults: defaults)
        )
        let request = WatchRelayRequest(
            operation: .bootstrap,
            baseURL: "http://home.local:8000",
            token: "watch-token",
            deviceID: "watch-1"
        )
        let encoded = try XCTUnwrap(WatchRelayCoding.encodeRequest(request))
        let reply = expectation(description: "relay reply")
        var response: WatchRelayResponse?
        coordinator.watchConnectivityDidReceiveMessage(
            ["kind": "relay", "request": encoded]
        ) { dictionary in
            response = (dictionary["response"] as? String)
                .flatMap(WatchRelayCoding.decodeResponse)
            reply.fulfill()
        }
        await fulfillment(of: [reply], timeout: 5)
        let value = try XCTUnwrap(response)
        XCTAssertTrue(value.ok)
        XCTAssertEqual(value.requestId, request.requestId)
        let bootstrap = try JSONDecoder.withSnakeCase.decode(
            BootstrapResponse.self, from: try XCTUnwrap(value.payload)
        )
        XCTAssertEqual(bootstrap.apiVersion, "1")
    }
}

private extension JSONDecoder {
    static var withSnakeCase: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

