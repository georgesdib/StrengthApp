import XCTest
import WatchConnectivity
@testable import StrengthApp
import StrengthCore

@MainActor
private final class FakeWatchConnectivity: WatchConnectivitySession {
    weak var delegate: WatchConnectivitySessionDelegate?
    var isSupported = true
    var isPaired = true
    var isWatchAppInstalled = true
    var activationState: WCSessionActivationState = .activated
    var receivedApplicationContext: [String: Any] = [:]
    private(set) var updates: [[String: Any]] = []

    func activate() {
        activationState = .activated
        delegate?.watchConnectivityDidChange()
    }

    func updateApplicationContext(_ context: [String: Any]) throws {
        updates.append(context)
    }

    func receive(_ context: [String: Any]) {
        delegate?.watchConnectivityDidReceive(context)
    }
}

@MainActor
final class WatchPairingTests: XCTestCase {
    private func makeStore() -> (PairedStore, UserDefaults, String) {
        let suite = "WatchPairingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = PairedStore(defaults: defaults)
        store.homeServerURL = "http://home.local:8000"
        return (store, defaults, suite)
    }

    private func mintBody(epoch: Int) -> Data {
        Data("""
        {
          "device": {
            "device_id": "watch-\(epoch)",
            "label": "Apple Watch",
            "kind": "watch",
            "parent_device_id": "phone-1",
            "credential_epoch": \(epoch)
          },
          "token": "watch-token-\(epoch)",
          "created_at": "2026-11-10T20:00:00+00:00",
          "replaced_device_id": null
        }
        """.utf8)
    }

    private func activeWatchBody(epoch: Int) -> Data {
        Data("""
        {
          "devices": [
            {
              "device_id": "watch-\(epoch)",
              "label": "Apple Watch",
              "kind": "watch",
              "parent_device_id": "phone-1",
              "credential_epoch": \(epoch),
              "created_at": "2026-11-10T20:00:00+00:00",
              "last_seen_at": null,
              "revoked_at": null
            }
          ]
        }
        """.utf8)
    }

    private func makeCoordinator(
        store: PairedStore,
        connectivity: FakeWatchConnectivity
    ) -> (WatchPairingCoordinator, StubTransport, () -> Int) {
        var mintCount = 0
        let transport = StubTransport { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path == "/api/ios/v1/devices/watch" {
                mintCount += 1
                return (201, self.mintBody(epoch: mintCount))
            }
            if request.httpMethod == "GET", path == "/api/ios/v1/devices" {
                return (200, self.activeWatchBody(epoch: max(1, mintCount)))
            }
            if request.httpMethod == "DELETE", path.hasPrefix("/api/ios/v1/devices/") {
                return (200, Data("""
                {
                  "device_id": "watch-1",
                  "revoked_at": "2026-11-10T20:01:00+00:00",
                  "already_revoked": false,
                  "revoked_watch_ids": ["watch-1"]
                }
                """.utf8))
            }
            return (404, Data())
        }
        let client = IOSAPIClient(transport: transport)
        let coordinator = WatchPairingCoordinator(
            client: client,
            store: store,
            connectivity: connectivity
        )
        return (coordinator, transport, { mintCount })
    }

    private var phoneSession: IOSSession {
        IOSSession(
            baseURL: URL(string: "http://home.local:8000")!,
            token: "phone-token",
            deviceID: "phone-1"
        )
    }

    func testPairSendsTokenThenAckMarksPaired() async {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectivity = FakeWatchConnectivity()
        let (coordinator, _, mintCount) = makeCoordinator(
            store: store, connectivity: connectivity
        )
        coordinator.start(session: phoneSession, homeBaseURL: store.homeServerURL)

        XCTAssertEqual(coordinator.phase, .notPaired)
        await coordinator.pair()

        XCTAssertEqual(mintCount(), 1)
        XCTAssertEqual(coordinator.phase, .waiting)
        XCTAssertEqual(coordinator.link?.epoch, 1)
        XCTAssertEqual(coordinator.link?.ackEpoch, 0)
        XCTAssertEqual(connectivity.updates.last?["epoch"] as? Int, 1)
        XCTAssertEqual(connectivity.updates.last?["token"] as? String, "watch-token-1")
        XCTAssertEqual(store.watchLink?.deviceID, "watch-1")

        let ack = WatchAcknowledgement(
            ackEpoch: 1, configVersion: 1, deviceID: "watch-1", status: .ready
        )
        connectivity.receive(ack.dictionary)

        XCTAssertEqual(coordinator.phase, .paired)
        XCTAssertEqual(coordinator.link?.ackEpoch, 1)
        XCTAssertEqual(store.watchLink?.ackEpoch, 1)

        let persisted = UserDefaults(suiteName: suite)!
            .data(forKey: "ios.watch.link")
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertFalse(persisted.contains("watch-token"))

        let updatesBeforeProbe = connectivity.updates.count
        await coordinator.foreground(session: phoneSession, homeBaseURL: store.homeServerURL)
        XCTAssertEqual(connectivity.updates.count, updatesBeforeProbe + 1)
        XCTAssertNil(connectivity.updates.last?["token"])
        XCTAssertEqual(connectivity.updates.last?["epoch"] as? Int, 1)
    }

    func testConfigChangeSendsSameEpochWithoutToken() async {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectivity = FakeWatchConnectivity()
        let (coordinator, _, _) = makeCoordinator(store: store, connectivity: connectivity)
        coordinator.start(session: phoneSession, homeBaseURL: store.homeServerURL)
        await coordinator.pair()
        connectivity.receive(WatchAcknowledgement(
            ackEpoch: 1, configVersion: 1, deviceID: "watch-1", status: .ready
        ).dictionary)

        store.bumpWatchConfigVersion()
        await coordinator.configurationChanged(homeBaseURL: store.homeServerURL)

        let update = connectivity.updates.last
        XCTAssertEqual(update?["epoch"] as? Int, 1)
        XCTAssertEqual(update?["configVersion"] as? Int, 2)
        XCTAssertNil(update?["token"])
        XCTAssertEqual(update?["homeBaseURL"] as? String, "http://home.local:8000")
    }

    func testMissingAckTriggersANewEpoch() async {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectivity = FakeWatchConnectivity()
        let (coordinator, _, mintCount) = makeCoordinator(
            store: store, connectivity: connectivity
        )
        coordinator.start(session: phoneSession, homeBaseURL: store.homeServerURL)
        await coordinator.pair()
        XCTAssertEqual(mintCount(), 1)

        connectivity.receive(WatchAcknowledgement(
            ackEpoch: 1, configVersion: 1, deviceID: "watch-1", status: .missing
        ).dictionary)

        for _ in 0..<50 where mintCount() < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(mintCount(), 2)
        XCTAssertEqual(coordinator.link?.epoch, 2)
        XCTAssertEqual(coordinator.phase, .waiting)
        XCTAssertEqual(connectivity.updates.last?["token"] as? String, "watch-token-2")
    }

    func testRevokeSuppressesAutoMintAndSendsRevokedContext() async {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectivity = FakeWatchConnectivity()
        let (coordinator, _, mintCount) = makeCoordinator(
            store: store, connectivity: connectivity
        )
        coordinator.start(session: phoneSession, homeBaseURL: store.homeServerURL)
        await coordinator.pair()
        connectivity.receive(WatchAcknowledgement(
            ackEpoch: 1, configVersion: 1, deviceID: "watch-1", status: .ready
        ).dictionary)

        await coordinator.revoke()

        XCTAssertEqual(coordinator.phase, .revoked)
        XCTAssertEqual(coordinator.link?.revoked, true)
        XCTAssertEqual(connectivity.updates.last?["status"] as? String, "revoked")
        XCTAssertNil(connectivity.updates.last?["token"])
        XCTAssertFalse(coordinator.canRevoke)

        await coordinator.foreground(session: phoneSession, homeBaseURL: store.homeServerURL)
        XCTAssertEqual(mintCount(), 1)
        XCTAssertEqual(store.watchLink?.revoked, true)
    }

    func testForegroundWithoutAPairedWatchDoesNotMint() async {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectivity = FakeWatchConnectivity()
        let (coordinator, _, mintCount) = makeCoordinator(
            store: store, connectivity: connectivity
        )
        coordinator.start(session: phoneSession, homeBaseURL: store.homeServerURL)

        await coordinator.foreground(session: phoneSession, homeBaseURL: store.homeServerURL)

        XCTAssertEqual(mintCount(), 0)
        XCTAssertEqual(coordinator.phase, .notPaired)
    }

    func testPairRequiresAValidHomeServer() async {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.homeServerURL = ""
        let connectivity = FakeWatchConnectivity()
        let (coordinator, _, mintCount) = makeCoordinator(
            store: store, connectivity: connectivity
        )
        coordinator.start(session: phoneSession, homeBaseURL: "")

        XCTAssertFalse(coordinator.canPair)
        await coordinator.pair()
        XCTAssertEqual(mintCount(), 0)
        XCTAssertNotNil(coordinator.errorMessage)
    }
}
