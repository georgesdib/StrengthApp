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

    private var awayPhoneSession: IOSSession {
        IOSSession(
            baseURL: URL(string: "http://away.local:8000")!,
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

    func testWatchAPICallsUseHomeWhenPhoneSessionIsAway() async throws {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectivity = FakeWatchConnectivity()
        let (coordinator, transport, _) = makeCoordinator(
            store: store, connectivity: connectivity
        )
        coordinator.start(session: awayPhoneSession, homeBaseURL: store.homeServerURL)
        await coordinator.pair()
        XCTAssertEqual(coordinator.phase, .waiting)

        connectivity.receive(WatchAcknowledgement(
            ackEpoch: 1, configVersion: 1, deviceID: "watch-1", status: .ready
        ).dictionary)
        await coordinator.foreground(
            session: awayPhoneSession,
            homeBaseURL: store.homeServerURL
        )
        await coordinator.revoke()

        XCTAssertFalse(transport.requests.isEmpty)
        XCTAssertTrue(transport.requests.allSatisfy { $0.url?.host == "home.local" })
        XCTAssertTrue(transport.requests.contains { $0.url?.path == "/api/ios/v1/devices/watch" })
        XCTAssertTrue(transport.requests.contains { $0.url?.path == "/api/ios/v1/devices" })
        XCTAssertTrue(transport.requests.contains {
            $0.httpMethod == "DELETE" && $0.url?.path == "/api/ios/v1/devices/watch-1"
        })
        XCTAssertEqual(coordinator.phase, .revoked)
    }

    func testHomeUnavailableDoesNotMintThroughAway() async {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectivity = FakeWatchConnectivity()
        var awayMintCount = 0
        let transport = StubTransport { request in
            if request.url?.host == "away.local" {
                awayMintCount += 1
                return (201, self.mintBody(epoch: 99))
            }
            throw URLError(.cannotConnectToHost)
        }
        let client = IOSAPIClient(transport: transport)
        let coordinator = WatchPairingCoordinator(
            client: client,
            store: store,
            connectivity: connectivity
        )
        coordinator.start(session: awayPhoneSession, homeBaseURL: store.homeServerURL)

        await coordinator.pair()

        XCTAssertEqual(awayMintCount, 0)
        XCTAssertEqual(coordinator.phase, .notPaired)
        XCTAssertTrue(coordinator.errorMessage?.contains("Home Server") == true)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.url?.host, "home.local")
    }

    func testHomeAuthenticationFailureDoesNotFallBackToAway() async {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectivity = FakeWatchConnectivity()
        var awayMintCount = 0
        let transport = StubTransport { request in
            if request.url?.host == "away.local" {
                awayMintCount += 1
                return (201, self.mintBody(epoch: 99))
            }
            return (401, Data("{}".utf8))
        }
        let client = IOSAPIClient(transport: transport)
        let coordinator = WatchPairingCoordinator(
            client: client,
            store: store,
            connectivity: connectivity
        )
        coordinator.start(session: awayPhoneSession, homeBaseURL: store.homeServerURL)

        await coordinator.pair()

        XCTAssertEqual(awayMintCount, 0)
        XCTAssertTrue(coordinator.errorMessage?.contains("Home Server rejected") == true)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.url?.host, "home.local")
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

    private func watchAck(
        epoch: Int = 1,
        config: Int,
        device: String = "watch-1",
        status: WatchCredentialStatus = .ready,
        home: String? = "http://home.local:8000"
    ) -> [String: Any] {
        WatchAcknowledgement(
            ackEpoch: epoch,
            configVersion: config,
            deviceID: device,
            status: status,
            homeBaseURL: home
        ).dictionary
    }

    func testWatchConfigAheadOfPhoneIsRebaselinedAndApplied() async {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectivity = FakeWatchConnectivity()
        let (coordinator, _, _) = makeCoordinator(store: store, connectivity: connectivity)
        coordinator.start(session: phoneSession, homeBaseURL: store.homeServerURL)
        await coordinator.pair()

        connectivity.receive(watchAck(config: 5))
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(coordinator.phase, .configuring)
        XCTAssertEqual(store.watchConfigVersion, 6)
        XCTAssertEqual(connectivity.updates.last?["configVersion"] as? Int, 6)
        XCTAssertTrue(connectivity.updates.last?["token"] == nil)

        connectivity.receive(watchAck(config: 6))
        XCTAssertEqual(coordinator.phase, .paired)
    }

    func testPhoneConfigResetBelowWatchRebaselines() async {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.watchConfigVersion = 1
        let connectivity = FakeWatchConnectivity()
        let (coordinator, _, _) = makeCoordinator(store: store, connectivity: connectivity)
        coordinator.start(session: phoneSession, homeBaseURL: store.homeServerURL)
        await coordinator.pair()

        connectivity.receive(watchAck(config: 9))
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(store.watchConfigVersion, 10)
        XCTAssertNotEqual(coordinator.phase, .paired)
        connectivity.receive(watchAck(config: 10))
        XCTAssertEqual(coordinator.phase, .paired)
    }

    func testOldHomeURLIsRebaselinedAndEventuallyApplied() async {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectivity = FakeWatchConnectivity()
        let (coordinator, _, _) = makeCoordinator(store: store, connectivity: connectivity)
        coordinator.start(session: phoneSession, homeBaseURL: store.homeServerURL)
        await coordinator.pair()

        connectivity.receive(watchAck(config: 1, home: "http://old.local:8000"))
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertNotEqual(coordinator.phase, .paired)
        XCTAssertEqual(store.watchConfigVersion, 2)
        XCTAssertEqual(connectivity.updates.last?["homeBaseURL"] as? String, "http://home.local:8000")
        XCTAssertEqual(connectivity.updates.last?["configVersion"] as? Int, 2)

        connectivity.receive(watchAck(config: 2))
        XCTAssertEqual(coordinator.phase, .paired)
    }

    func testDuplicateConfigurationAcknowledgementIsIdempotent() async {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectivity = FakeWatchConnectivity()
        let (coordinator, _, _) = makeCoordinator(store: store, connectivity: connectivity)
        coordinator.start(session: phoneSession, homeBaseURL: store.homeServerURL)
        await coordinator.pair()
        connectivity.receive(watchAck(config: 1))
        XCTAssertEqual(coordinator.phase, .paired)
        let updateCount = connectivity.updates.count

        connectivity.receive(watchAck(config: 1))
        XCTAssertEqual(coordinator.phase, .paired)
        XCTAssertEqual(connectivity.updates.count, updateCount)
    }

    func testConfigurationReconciliationIsBounded() async {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectivity = FakeWatchConnectivity()
        let (coordinator, _, _) = makeCoordinator(store: store, connectivity: connectivity)
        coordinator.start(session: phoneSession, homeBaseURL: store.homeServerURL)
        await coordinator.pair()

        connectivity.receive(watchAck(config: 9, home: "http://old.local:8000"))
        try? await Task.sleep(nanoseconds: 20_000_000)
        connectivity.receive(watchAck(config: 9, home: "http://old.local:8000"))
        try? await Task.sleep(nanoseconds: 20_000_000)
        let updateCount = connectivity.updates.count

        connectivity.receive(watchAck(config: 9, home: "http://old.local:8000"))
        XCTAssertEqual(connectivity.updates.count, updateCount)
        XCTAssertNotEqual(coordinator.phase, .paired)
        XCTAssertTrue(coordinator.errorMessage?.contains("configuration") == true)
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

    func testDifferentDeviceAckWithHigherEpochRequestsFreshMintAndConverges() async {
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
        XCTAssertEqual(coordinator.phase, .paired)

        // The watch still holds a different device credential. A tokenless probe cannot
        // replace it, so the phone must mint a fresh epoch and send the token.
        connectivity.receive(WatchAcknowledgement(
            ackEpoch: 99, configVersion: 1, deviceID: "watch-stale", status: .ready
        ).dictionary)

        for _ in 0..<50 where mintCount() < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(mintCount(), 2)
        XCTAssertEqual(coordinator.link?.epoch, 2)
        XCTAssertNotEqual(coordinator.phase, .paired)
        XCTAssertEqual(connectivity.updates.last?["token"] as? String, "watch-token-2")

        connectivity.receive(WatchAcknowledgement(
            ackEpoch: 2, configVersion: 1, deviceID: "watch-2", status: .ready
        ).dictionary)
        XCTAssertEqual(coordinator.phase, .paired)
        XCTAssertEqual(coordinator.link?.ackEpoch, 2)
    }

    func testDifferentDeviceAckWithLowerEpochRequestsFreshMint() async {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectivity = FakeWatchConnectivity()
        let (coordinator, _, mintCount) = makeCoordinator(
            store: store, connectivity: connectivity
        )
        coordinator.start(session: phoneSession, homeBaseURL: store.homeServerURL)
        await coordinator.pair()
        connectivity.receive(watchAck(config: 1))

        connectivity.receive(WatchAcknowledgement(
            ackEpoch: 0, configVersion: 1, deviceID: "watch-stale", status: .ready
        ).dictionary)
        for _ in 0..<50 where mintCount() < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(mintCount(), 2)
        XCTAssertNotEqual(coordinator.phase, .paired)
        XCTAssertEqual(connectivity.updates.last?["token"] as? String, "watch-token-2")
    }

    func testSameDeviceStaleReadyAckRequestsFreshMint() async {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectivity = FakeWatchConnectivity()
        let (coordinator, _, mintCount) = makeCoordinator(
            store: store, connectivity: connectivity
        )
        coordinator.start(session: phoneSession, homeBaseURL: store.homeServerURL)
        await coordinator.pair()
        XCTAssertEqual(coordinator.link?.ackEpoch, 0)

        // Simulate app termination after minting but before the acknowledgement: the phone
        // has lost the in-memory token, so a stale watch ack must trigger a fresh mint.
        coordinator.stop()
        coordinator.start(session: phoneSession, homeBaseURL: store.homeServerURL)

        connectivity.receive(WatchAcknowledgement(
            ackEpoch: 0, configVersion: 1, deviceID: "watch-1", status: .ready
        ).dictionary)
        for _ in 0..<50 where mintCount() < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(mintCount(), 2)
        XCTAssertEqual(coordinator.link?.epoch, 2)
        XCTAssertNotEqual(coordinator.phase, .paired)
    }

    func testDelayedSameDeviceStaleAckAfterPairedDoesNotMint() async {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectivity = FakeWatchConnectivity()
        let (coordinator, _, mintCount) = makeCoordinator(
            store: store, connectivity: connectivity
        )
        coordinator.start(session: phoneSession, homeBaseURL: store.homeServerURL)
        await coordinator.pair()
        connectivity.receive(watchAck(config: 1))
        XCTAssertEqual(coordinator.phase, .paired)

        connectivity.receive(WatchAcknowledgement(
            ackEpoch: 0, configVersion: 1, deviceID: "watch-1", status: .ready
        ).dictionary)

        XCTAssertEqual(mintCount(), 1)
        XCTAssertEqual(coordinator.phase, .paired)
    }

    func testMissingAckForDifferentDeviceRequestsFreshMint() async {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectivity = FakeWatchConnectivity()
        let (coordinator, _, mintCount) = makeCoordinator(
            store: store, connectivity: connectivity
        )
        coordinator.start(session: phoneSession, homeBaseURL: store.homeServerURL)
        await coordinator.pair()
        connectivity.receive(watchAck(config: 1))

        connectivity.receive(WatchAcknowledgement(
            ackEpoch: 1, configVersion: 1, deviceID: "watch-stale", status: .missing
        ).dictionary)
        for _ in 0..<50 where mintCount() < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(mintCount(), 2)
        XCTAssertEqual(connectivity.updates.last?["token"] as? String, "watch-token-2")
    }

    func testRepeatedStaleAcknowledgementsDoNotDuplicateMintInFlight() async {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectivity = FakeWatchConnectivity()
        let (coordinator, _, mintCount) = makeCoordinator(
            store: store, connectivity: connectivity
        )
        coordinator.start(session: phoneSession, homeBaseURL: store.homeServerURL)
        await coordinator.pair()
        connectivity.receive(watchAck(config: 1))

        let stale = WatchAcknowledgement(
            ackEpoch: 99, configVersion: 1, deviceID: "watch-stale", status: .ready
        ).dictionary
        connectivity.receive(stale)
        connectivity.receive(stale)
        connectivity.receive(stale)

        for _ in 0..<50 where mintCount() < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(mintCount(), 2)
        XCTAssertEqual(coordinator.link?.epoch, 2)
    }

    func testForeignAckRecoveryStopsAfterBoundedAutomaticMints() async {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectivity = FakeWatchConnectivity()
        let (coordinator, _, mintCount) = makeCoordinator(
            store: store, connectivity: connectivity
        )
        coordinator.start(session: phoneSession, homeBaseURL: store.homeServerURL)
        await coordinator.pair()
        connectivity.receive(watchAck(config: 1))

        let foreign = WatchAcknowledgement(
            ackEpoch: 99, configVersion: 1, deviceID: "watch-stale", status: .ready
        ).dictionary
        connectivity.receive(foreign)
        for _ in 0..<50 where mintCount() < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(mintCount(), 2)
        connectivity.receive(watchAck(epoch: 2, config: 1, device: "watch-2"))

        connectivity.receive(foreign)
        for _ in 0..<50 where mintCount() < 3 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(mintCount(), 3)
        connectivity.receive(watchAck(epoch: 3, config: 1, device: "watch-3"))

        connectivity.receive(foreign)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(mintCount(), 3)
        XCTAssertTrue(coordinator.errorMessage?.contains("Pair Apple Watch") == true)
    }

    func testRevokedAckFromUnrelatedDeviceDoesNotRevokeCurrentLink() async {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectivity = FakeWatchConnectivity()
        let (coordinator, _, _) = makeCoordinator(store: store, connectivity: connectivity)
        coordinator.start(session: phoneSession, homeBaseURL: store.homeServerURL)
        await coordinator.pair()
        connectivity.receive(watchAck(config: 1))
        XCTAssertEqual(coordinator.phase, .paired)

        connectivity.receive(watchAck(
            epoch: 99,
            config: 1,
            device: "other-watch",
            status: .revoked
        ))

        XCTAssertEqual(coordinator.phase, .paired)
        XCTAssertEqual(coordinator.link?.revoked, false)
        XCTAssertEqual(store.watchLink?.revoked, false)
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

    func testStartWithRevokedLinkSendsRevokedContext() async {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.watchLink = PairedWatch(
            deviceID: "watch-1",
            label: "Apple Watch",
            epoch: 1,
            ackEpoch: 0,
            configVersion: 1,
            revoked: true,
            lastAckAt: nil
        )
        let connectivity = FakeWatchConnectivity()
        let (coordinator, _, _) = makeCoordinator(store: store, connectivity: connectivity)
        coordinator.start(session: phoneSession, homeBaseURL: store.homeServerURL)
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(coordinator.phase, .revoked)
        XCTAssertEqual(connectivity.updates.last?["status"] as? String, "revoked")
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
