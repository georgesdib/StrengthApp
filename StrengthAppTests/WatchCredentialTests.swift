import XCTest
@testable import StrengthApp
import StrengthCore

@MainActor
final class WatchCredentialTests: XCTestCase {
    private func context(
        epoch: Int = 1,
        configVersion: Int = 1,
        token: String? = "watch-token",
        status: WatchCredentialStatus = .ready,
        deviceID: String = "watch-1",
        home: String = "http://home.local:8000"
    ) -> WatchCredentialContext {
        WatchCredentialContext(
            epoch: epoch,
            configVersion: configVersion,
            homeBaseURL: home,
            deviceID: deviceID,
            token: token,
            issuedAt: "2026-11-10T20:00:00Z",
            status: status
        )
    }

    func testContextRoundTripsAndValidates() throws {
        let original = context()
        let decoded = try WatchCredentialContext(dictionary: original.dictionary)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(try decoded.validated(), original)
    }

    func testContextRejectsUnsupportedSchemaAndInvalidFields() {
        XCTAssertThrowsError(try WatchCredentialContext(
            schema: 2, epoch: 1, configVersion: 1,
            homeBaseURL: "http://home.local:8000", deviceID: "watch-1",
            token: "token", issuedAt: "now"
        ).validated())

        XCTAssertThrowsError(try context(home: "not a url").validated())
        XCTAssertThrowsError(try context(token: " ").validated())
        XCTAssertThrowsError(try context(token: "token", status: .revoked).validated())
        XCTAssertThrowsError(try WatchCredentialContext(
            epoch: 0, configVersion: 1, homeBaseURL: "http://home.local:8000",
            deviceID: "watch-1", token: "token", issuedAt: "now"
        ).validated())
    }

    func testAcknowledgementRoundTrips() throws {
        let ack = WatchAcknowledgement(
            ackEpoch: 3, configVersion: 4, deviceID: "watch-1", status: .ready
        )
        XCTAssertEqual(try WatchAcknowledgement(dictionary: ack.dictionary), ack)
    }

    func testPolicyAcceptsNewEpochAndRejectsStaleOrRevokedRollback() {
        let stored = WatchStoredCredential(
            deviceID: "watch-1", epoch: 2, configVersion: 3,
            homeBaseURL: "http://home.local:8000"
        )

        XCTAssertEqual(
            WatchCredentialPolicy.decision(
                for: context(epoch: 3, configVersion: 3, token: "new"),
                stored: stored, hasToken: true
            ),
            .applyToken
        )
        XCTAssertEqual(
            WatchCredentialPolicy.decision(
                for: context(epoch: 1, configVersion: 3, token: "old"),
                stored: stored, hasToken: true
            ),
            .ignoreAndReack
        )
        XCTAssertEqual(
            WatchCredentialPolicy.decision(
                for: context(epoch: 2, configVersion: 4, token: nil),
                stored: stored, hasToken: true
            ),
            .applyConfiguration
        )
        XCTAssertEqual(
            WatchCredentialPolicy.decision(
                for: context(epoch: 2, configVersion: 3, token: nil),
                stored: stored, hasToken: true
            ),
            .ignoreAndReack
        )
        XCTAssertEqual(
            WatchCredentialPolicy.decision(
                for: context(epoch: 2, configVersion: 4, token: "new", deviceID: "watch-2"),
                stored: stored, hasToken: true
            ),
            .ignoreAndReack
        )
        XCTAssertEqual(
            WatchCredentialPolicy.decision(
                for: context(epoch: 3, configVersion: 4, token: nil, status: .revoked),
                stored: stored, hasToken: true
            ),
            .revoke
        )
    }

    func testStoreAppliesTokenConfigAndRevocationWithoutPersistingToken() throws {
        let suite = "WatchCredentialTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let tokens = InMemoryTokenStore()
        let store = WatchCredentialStore(defaults: defaults, tokens: tokens)

        XCTAssertEqual(try store.apply(context()), .applyToken)
        XCTAssertEqual(store.stored?.epoch, 1)
        XCTAssertEqual(store.loadToken(), "watch-token")
        XCTAssertEqual(store.acknowledgement()?.status, .ready)

        XCTAssertEqual(
            try store.apply(context(configVersion: 2, token: nil, home: "http://home2.local:8000")),
            .applyConfiguration
        )
        XCTAssertEqual(store.stored?.configVersion, 2)
        XCTAssertEqual(store.stored?.homeBaseURL, "http://home2.local:8000")
        XCTAssertEqual(store.loadToken(), "watch-token")
        XCTAssertEqual(store.acknowledgement()?.configVersion, 2)

        XCTAssertEqual(
            try store.apply(context(epoch: 2, token: "second-token")),
            .applyToken
        )
        XCTAssertEqual(store.loadToken(), "second-token")

        XCTAssertEqual(
            try store.apply(context(epoch: 2, token: nil, status: .revoked)),
            .revoke
        )
        XCTAssertFalse(store.hasToken)
        XCTAssertEqual(store.acknowledgement()?.status, .revoked)

        let allDefaults = defaults.dictionaryRepresentation().values
            .compactMap { $0 as? Data }
            .compactMap { String(data: $0, encoding: .utf8) }
            .joined()
        XCTAssertFalse(allDefaults.contains("watch-token"))
        XCTAssertFalse(allDefaults.contains("second-token"))
    }

    func testTokenlessProbeStoresMetadataAndAcknowledgesMissing() throws {
        let suite = "WatchCredentialTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchCredentialStore(defaults: defaults, tokens: InMemoryTokenStore())

        XCTAssertEqual(
            try store.apply(context(epoch: 3, configVersion: 5, token: nil)),
            .missingToken
        )
        XCTAssertEqual(store.stored?.epoch, 3)
        XCTAssertFalse(store.hasToken)
        XCTAssertEqual(store.acknowledgement()?.status, .missing)

        XCTAssertEqual(
            try store.apply(context(epoch: 4, configVersion: 5, token: "new-token")),
            .applyToken
        )
        XCTAssertEqual(store.acknowledgement()?.status, .ready)
    }

    func testStoreMarksCredentialsMissingForA401() throws {
        let suite = "WatchCredentialTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let tokens = InMemoryTokenStore()
        let store = WatchCredentialStore(defaults: defaults, tokens: tokens)

        _ = try store.apply(context())
        store.markCredentialsMissing()
        XCTAssertFalse(store.hasToken)
        XCTAssertEqual(store.acknowledgement()?.status, .missing)
    }

    func testWatchKeychainUsesItsOwnServiceAndAccount() {
        XCTAssertNotEqual(
            WatchCredentialStore.keychainService,
            KeychainTokenStore.defaultService
        )
        XCTAssertEqual(WatchCredentialStore.keychainAccount, KeychainTokenStore.defaultAccount)
    }
}
