import XCTest
@testable import StrengthApp

final class ServerConfigurationTests: XCTestCase {
    func testMatchingHomeWiFiSelectsHomeServer() {
        let selection = ServerConfiguration.select(
            homeURL: "http://192.168.1.10:8000",
            awayURL: "http://away.example:8000",
            homeWiFi: "HomeNet",
            currentSSID: "HomeNet"
        )
        XCTAssertEqual(selection?.route, .home)
        XCTAssertEqual(selection?.url, "http://192.168.1.10:8000")
    }

    func testDifferentWiFiSelectsAwayServer() {
        let selection = ServerConfiguration.select(
            homeURL: "http://192.168.1.10:8000",
            awayURL: "http://away.example:8000",
            homeWiFi: "HomeNet",
            currentSSID: "CoffeeShop"
        )
        XCTAssertEqual(selection?.route, .away)
        XCTAssertEqual(selection?.url, "http://away.example:8000")
    }

    func testUnavailableSSIDUsesAwayServer() {
        let selection = ServerConfiguration.select(
            homeURL: "http://192.168.1.10:8000",
            awayURL: "http://away.example:8000",
            homeWiFi: "HomeNet",
            currentSSID: nil
        )
        XCTAssertEqual(selection?.route, .away)
    }

    func testAwayFallsBackToHomeWhenUnset() {
        let selection = ServerConfiguration.select(
            homeURL: "http://192.168.1.10:8000",
            awayURL: "",
            homeWiFi: "HomeNet",
            currentSSID: "CoffeeShop"
        )
        XCTAssertEqual(selection?.route, .home)
        XCTAssertEqual(selection?.url, "http://192.168.1.10:8000")
    }

    func testNoConfiguredServerReturnsNil() {
        XCTAssertNil(ServerConfiguration.select(
            homeURL: " ",
            awayURL: "",
            homeWiFi: "HomeNet",
            currentSSID: "HomeNet"
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
    }

    @MainActor
    func testAppModelSwitchesToAwayAddressWhenWiFiChanges() async {
        let suite = "ServerConfigurationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PairedStore(defaults: defaults)
        store.serverURL = "http://home.local:8000"
        store.homeServerURL = "http://home.local:8000"
        store.awayServerURL = "http://away.local:8000"
        store.homeWiFi = "HomeNet"
        store.device = PairingDevice(deviceID: "device-1", label: "iPhone")

        let transport = StubTransport { request in
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
        let wifi = StubWiFiSSID(ssid: "HomeNet")
        let offlineURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("server-route-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: offlineURL) }
        let model = AppModel(
            client: IOSAPIClient(transport: transport),
            tokens: InMemoryTokenStore(token: "token-abc"),
            store: store,
            healthKitDefaults: defaults,
            offlineStore: OfflineCaptureStore(fileURL: offlineURL),
            wifi: wifi
        )
        await model.onLaunch()
        XCTAssertEqual(model.activeServerRoute, .home)
        XCTAssertEqual(model.serverURLText, "http://home.local:8000")

        wifi.ssid = "CoffeeShop"
        await model.appBecameActive()
        XCTAssertEqual(model.activeServerRoute, .away)
        XCTAssertEqual(model.serverURLText, "http://away.local:8000")
    }
}

private final class StubWiFiSSID: WiFiSSIDProviding {
    var ssid: String?
    init(ssid: String?) { self.ssid = ssid }
    func currentSSID() async -> String? { ssid }
}
