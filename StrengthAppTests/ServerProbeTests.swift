import XCTest

@testable import StrengthApp
import StrengthCore

/// The Home/Away probe keeps the reason, so "the server is off", "iOS refuses this address" and
/// "the server refused this device" stay distinguishable. Routing still only acts on
/// `isReachable`, and a 5xx still falls through to the Away Server exactly as before.
@MainActor
final class ServerProbeTests: XCTestCase {
    private let baseURL = URL(string: "http://home.local:8000")!

    private func probe(_ handler: @escaping (URLRequest) throws -> (Int, Data)) async -> ServerProbeResult {
        let client = IOSAPIClient(transport: StubTransport(handler: handler))
        return await client.probeServer(baseURL: baseURL, token: "token-abc")
    }

    func testSuccessfulBootstrapIsReachable() async {
        let result = await probe { _ in (200, Data("{}".utf8)) }
        XCTAssertEqual(result, .reachable)
        XCTAssertTrue(result.isReachable)
    }

    func testRejectedCredentialIsReachableButNamed() async {
        let result = await probe { _ in (401, Data()) }
        XCTAssertEqual(result, .unauthorized)
        XCTAssertTrue(result.isReachable, "switching server cannot fix a stale token")
    }

    func testServerErrorFallsThroughToAway() async {
        let result = await probe { _ in (503, Data()) }
        XCTAssertEqual(result, .serverError(status: 503))
        XCTAssertFalse(result.isReachable)
    }

    func testBlockedCleartextAddressIsNotReportedAsUnreachable() async {
        let result = await probe { _ in
            throw URLError(.appTransportSecurityRequiresSecureConnection)
        }
        XCTAssertEqual(result, .blockedByPolicy)
        XCTAssertFalse(result.isReachable)
    }

    func testTransportFailureIsUnreachable() async {
        let result = await probe { _ in throw URLError(.cannotConnectToHost) }
        XCTAssertEqual(result, .unreachable)
        XCTAssertFalse(result.isReachable)
    }

    /// A stored address saved before the check existed must still be flagged, without editing it.
    func testStoredUnloadableAwayAddressWarnsOnLaunch() async {
        let suite = "ServerProbeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PairedStore(defaults: defaults)
        store.serverURL = "http://home.local:8000"
        store.homeServerURL = "http://home.local:8000"
        store.awayServerURL = "http://odroid.tailnet.ts.net:8000"
        store.preferHome = true
        store.device = PairingDevice(deviceID: "device-1", label: "iPhone")

        let transport = StubTransport { request in
            if request.url?.host == "home.local" { return (503, Data()) }
            return (200, Data(Fixtures.bootstrapPhase2.utf8))
        }
        let offlineURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-warning-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: offlineURL) }
        let model = AppModel(
            client: IOSAPIClient(transport: transport),
            tokens: InMemoryTokenStore(token: "token-abc"),
            store: store,
            healthKitDefaults: defaults,
            offlineStore: OfflineCaptureStore(fileURL: offlineURL)
        )
        await model.onLaunch()

        let warning = try? XCTUnwrap(model.serverSettingsWarning)
        XCTAssertTrue(warning?.contains("Away Server") == true, "unexpected warning: \(String(describing: warning))")
        XCTAssertEqual(model.activeServerRoute, .away)
    }

    func testLocalAwayAddressDoesNotWarn() async {
        let suite = "ServerProbeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PairedStore(defaults: defaults)
        store.serverURL = "http://home.local:8000"
        store.homeServerURL = "http://home.local:8000"
        store.awayServerURL = "http://192.168.1.20:8000"
        store.preferHome = true
        store.device = PairingDevice(deviceID: "device-1", label: "iPhone")

        let transport = StubTransport { _ in (200, Data(Fixtures.bootstrapPhase2.utf8)) }
        let offlineURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-clean-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: offlineURL) }
        let model = AppModel(
            client: IOSAPIClient(transport: transport),
            tokens: InMemoryTokenStore(token: "token-abc"),
            store: store,
            healthKitDefaults: defaults,
            offlineStore: OfflineCaptureStore(fileURL: offlineURL)
        )
        await model.onLaunch()
        XCTAssertNil(model.serverSettingsWarning)
    }
}
