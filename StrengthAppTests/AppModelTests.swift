import XCTest

@testable import StrengthApp
import StrengthCore

@MainActor
final class AppModelTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "com.georgesdibpersonalteam.StrengthApp.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    func test401ClearsTheLocalPairingButKeepsTheServerURL() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PairedStore(defaults: defaults)
        store.serverURL = "http://127.0.0.1:8000"
        store.device = PairingDevice(deviceID: "device-1", label: "iPhone")
        let tokens = InMemoryTokenStore(token: "token-abc")
        let transport = StubTransport { _ in (401, Data()) }
        let model = AppModel(
            client: IOSAPIClient(transport: transport),
            tokens: tokens,
            store: store
        )

        await model.onLaunch()

        XCTAssertEqual(model.phase, .pairing)
        XCTAssertNil(tokens.token)
        XCTAssertNil(store.device)
        XCTAssertEqual(store.serverURL, "http://127.0.0.1:8000")
        XCTAssertEqual(model.serverURLText, "http://127.0.0.1:8000")
        XCTAssertEqual(model.pairingError, APIError.unauthorized.errorDescription)
    }

    func test403AlsoClearsTheLocalPairing() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PairedStore(defaults: defaults)
        store.serverURL = "http://127.0.0.1:8000"
        store.device = PairingDevice(deviceID: "device-1", label: "iPhone")
        let tokens = InMemoryTokenStore(token: "token-abc")
        let transport = StubTransport { _ in (403, Data()) }
        let model = AppModel(
            client: IOSAPIClient(transport: transport),
            tokens: tokens,
            store: store
        )

        await model.onLaunch()

        XCTAssertEqual(model.phase, .pairing)
        XCTAssertNil(tokens.token)
        XCTAssertEqual(model.pairingError, APIError.forbidden.errorDescription)
    }

    func testPairStoresTheTokenAndLoadsToday() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PairedStore(defaults: defaults)
        let tokens = InMemoryTokenStore()
        let transport = StubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/pair":
                return (200, Data(Fixtures.pair.utf8))
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrap.utf8))
            case "/api/ios/v1/today":
                return (200, Data(Fixtures.today.utf8))
            default:
                return (404, Data())
            }
        }
        let model = AppModel(
            client: IOSAPIClient(transport: transport),
            tokens: tokens,
            store: store
        )
        model.serverURLText = "http://127.0.0.1:8000/"
        model.pairingCodeText = "1234 5678"
        model.pairingLabelText = "Gym iPhone"

        await model.pair()

        XCTAssertEqual(model.phase, .paired)
        XCTAssertEqual(tokens.token, "token-abc")
        XCTAssertEqual(store.device?.deviceID, "device-1")
        XCTAssertEqual(store.serverURL, "http://127.0.0.1:8000")
        XCTAssertEqual(model.today?.date, "2026-11-07")
        XCTAssertNil(model.pairingError)
        XCTAssertEqual(model.pairedServerURL, "http://127.0.0.1:8000")
    }

    func testPairingInputErrorsDoNotCreateADevice() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PairedStore(defaults: defaults)
        let tokens = InMemoryTokenStore()
        let transport = StubTransport { _ in
            XCTFail("the client must not be called for invalid input")
            return (500, Data())
        }
        let model = AppModel(
            client: IOSAPIClient(transport: transport),
            tokens: tokens,
            store: store
        )
        model.serverURLText = "http://127.0.0.1:8000"
        model.pairingCodeText = "1234"

        await model.pair()

        XCTAssertEqual(model.phase, .loading)
        XCTAssertNil(tokens.token)
        XCTAssertEqual(
            model.pairingError,
            APIError.invalidPairingCode.errorDescription
        )
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testForgetDeviceKeepsTheServerURLForRePairing() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PairedStore(defaults: defaults)
        store.serverURL = "http://127.0.0.1:8000"
        store.device = PairingDevice(deviceID: "device-1", label: "iPhone")
        let tokens = InMemoryTokenStore(token: "token-abc")
        let transport = StubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrap.utf8))
            case "/api/ios/v1/today":
                return (200, Data(Fixtures.today.utf8))
            default:
                return (404, Data())
            }
        }
        let model = AppModel(
            client: IOSAPIClient(transport: transport),
            tokens: tokens,
            store: store
        )
        await model.onLaunch()
        XCTAssertEqual(model.phase, .paired)

        model.forgetDevice()

        XCTAssertEqual(model.phase, .pairing)
        XCTAssertNil(tokens.token)
        XCTAssertNil(store.device)
        XCTAssertEqual(store.serverURL, "http://127.0.0.1:8000")
        XCTAssertNil(model.today)
        XCTAssertNil(model.pairingError)
    }
}
