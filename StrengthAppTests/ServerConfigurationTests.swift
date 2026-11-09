import XCTest
@testable import StrengthApp
import StrengthCore

@MainActor
final class ServerConfigurationTests: XCTestCase {
    func testPreferredReachableHomeSelectsHomeServer() {
        let selection = ServerConfiguration.select(
            homeURL: "http://192.168.1.10:8000",
            awayURL: "http://away.example:8000",
            preferHome: true,
            homeReachable: true
        )
        XCTAssertEqual(selection?.route, .home)
        XCTAssertEqual(selection?.url, "http://192.168.1.10:8000")
    }

    func testUnreachableHomeSelectsAwayServer() {
        let selection = ServerConfiguration.select(
            homeURL: "http://192.168.1.10:8000",
            awayURL: "http://away.example:8000",
            preferHome: true,
            homeReachable: false
        )
        XCTAssertEqual(selection?.route, .away)
        XCTAssertEqual(selection?.url, "http://away.example:8000")
    }

    func testManualAwayOverrideSelectsAwayServer() {
        let selection = ServerConfiguration.select(
            homeURL: "http://192.168.1.10:8000",
            awayURL: "http://away.example:8000",
            preferHome: false,
            homeReachable: true
        )
        XCTAssertEqual(selection?.route, .away)
        XCTAssertEqual(selection?.url, "http://away.example:8000")
    }

    func testUnprobedPreferredHomeSelectsHomeServer() {
        let selection = ServerConfiguration.select(
            homeURL: "http://192.168.1.10:8000",
            awayURL: "http://away.example:8000",
            preferHome: true,
            homeReachable: nil
        )
        XCTAssertEqual(selection?.route, .home)
    }

    func testAwayFallsBackToHomeWhenUnset() {
        let selection = ServerConfiguration.select(
            homeURL: "http://192.168.1.10:8000",
            awayURL: "",
            preferHome: true,
            homeReachable: false
        )
        XCTAssertEqual(selection?.route, .home)
        XCTAssertEqual(selection?.url, "http://192.168.1.10:8000")
    }

    func testNoConfiguredServerReturnsNil() {
        XCTAssertNil(ServerConfiguration.select(
            homeURL: " ",
            awayURL: "",
            preferHome: true,
            homeReachable: nil
        ))
    }

    func testLegacySingleServerMigratesToHome() {
        let suite = "ServerConfigurationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PairedStore(defaults: defaults)
        store.serverURL = "http://192.168.1.10:8000"
        store.migrateServerConfigurationIfNeeded()
        XCTAssertEqual(store.homeServerURL, "http://192.168.1.10:8000")
        XCTAssertEqual(store.awayServerURL, nil)
        XCTAssertTrue(store.preferHome)
    }

    @MainActor
    func testAppModelUsesAwayAddressWhenHomeIsUnreachable() async {
        let suite = "ServerConfigurationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PairedStore(defaults: defaults)
        store.serverURL = "http://home.local:8000"
        store.homeServerURL = "http://home.local:8000"
        store.awayServerURL = "http://away.local:8000"
        store.preferHome = true
        store.device = PairingDevice(deviceID: "device-1", label: "iPhone")

        let transport = StubTransport { request in
            guard let host = request.url?.host else { return (500, Data()) }
            if host == "home.local" { return (500, Data()) }
            switch request.url?.path {
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrapPhase2.utf8))
            case "/api/ios/v1/today":
                return (200, Data(Fixtures.today.utf8))
            case "/api/ios/v1/plans/current":
                return (200, Data(Fixtures.plansReady.utf8))
            default:
                return (404, Data())
            }
        }
        let offlineURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("server-route-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: offlineURL) }
        let model = AppModel(
            client: IOSAPIClient(transport: transport),
            tokens: InMemoryTokenStore(token: "token-abc"),
            store: store,
            healthKitDefaults: defaults,
            offlineStore: OfflineCaptureStore(fileURL: offlineURL)
        )
        await model.onLaunch()
        XCTAssertEqual(model.activeServerRoute, .away)
        XCTAssertEqual(model.serverURLText, "http://away.local:8000")
        XCTAssertEqual(model.homeServerReachable, false)
    }
}
