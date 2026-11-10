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
            ackEpoch: 3,
            configVersion: 4,
            deviceID: "watch-1",
            status: .ready,
            homeBaseURL: "http://home.local:8000"
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
            .applyToken
        )
        XCTAssertEqual(
            WatchCredentialPolicy.decision(
                for: context(epoch: 3, configVersion: 4, token: nil, status: .revoked),
                stored: stored, hasToken: true
            ),
            .revoke
        )
    }

    private func stored(
        deviceID: String = "watch-1",
        epoch: Int = 2,
        configVersion: Int = 3,
        revoked: Bool = false
    ) -> WatchStoredCredential {
        WatchStoredCredential(
            deviceID: deviceID,
            epoch: epoch,
            configVersion: configVersion,
            homeBaseURL: "http://home.local:8000",
            revoked: revoked
        )
    }

    func testRevocationForDifferentDeviceIsIgnoredAtHigherEpoch() {
        let existing = stored(deviceID: "watch-1", epoch: 2)
        let incoming = context(
            epoch: 9, configVersion: 4, token: nil, status: .revoked, deviceID: "watch-2"
        )
        XCTAssertEqual(
            WatchCredentialPolicy.decision(for: incoming, stored: existing, hasToken: true),
            .ignoreAndReack
        )
    }

    func testRevocationForDifferentDeviceIsIgnoredAtSameEpoch() {
        let existing = stored(deviceID: "watch-1", epoch: 2)
        let incoming = context(
            epoch: 2, configVersion: 4, token: nil, status: .revoked, deviceID: "watch-2"
        )
        XCTAssertEqual(
            WatchCredentialPolicy.decision(for: incoming, stored: existing, hasToken: true),
            .ignoreAndReack
        )
    }

    func testRevocationForMatchingDeviceAndValidEpochIsAccepted() {
        let existing = stored(deviceID: "watch-1", epoch: 2)
        XCTAssertEqual(
            WatchCredentialPolicy.decision(
                for: context(epoch: 3, token: nil, status: .revoked),
                stored: existing, hasToken: true
            ),
            .revoke
        )
        XCTAssertEqual(
            WatchCredentialPolicy.decision(
                for: context(epoch: 2, token: nil, status: .revoked),
                stored: existing, hasToken: true
            ),
            .revoke
        )
    }

    func testStaleRevocationForMatchingDeviceIsIgnored() {
        let existing = stored(deviceID: "watch-1", epoch: 3)
        XCTAssertEqual(
            WatchCredentialPolicy.decision(
                for: context(epoch: 2, token: nil, status: .revoked),
                stored: existing, hasToken: true
            ),
            .ignoreAndReack
        )
    }

    func testIgnoredCrossDeviceRevocationLeavesCredentialAndMetadataUntouched() throws {
        let suite = "WatchCredentialTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let tokens = InMemoryTokenStore()
        let store = WatchCredentialStore(defaults: defaults, tokens: tokens)
        _ = try store.apply(context(epoch: 2, token: "watch-token"))
        let before = store.stored
        let acknowledgementBefore = store.acknowledgement()

        XCTAssertEqual(
            try store.apply(context(
                epoch: 9, token: nil, status: .revoked, deviceID: "watch-2"
            )),
            .ignoreAndReack
        )
        XCTAssertEqual(store.loadToken(), "watch-token")
        XCTAssertEqual(store.stored, before)
        XCTAssertEqual(store.acknowledgement(), acknowledgementBefore)
        XCTAssertEqual(store.acknowledgement()?.status, .ready)

        // A stale revocation for the matching device is also ignored.
        XCTAssertEqual(
            try store.apply(context(epoch: 1, token: nil, status: .revoked)),
            .ignoreAndReack
        )
        XCTAssertEqual(store.loadToken(), "watch-token")
        XCTAssertEqual(store.stored, before)
        XCTAssertEqual(store.acknowledgement(), acknowledgementBefore)
    }

    func testDuplicateRevocationIsIdempotent() throws {
        let suite = "WatchCredentialTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let tokens = InMemoryTokenStore()
        let store = WatchCredentialStore(defaults: defaults, tokens: tokens)
        _ = try store.apply(context(epoch: 2, token: "watch-token"))
        let revocation = context(epoch: 2, token: nil, status: .revoked)
        let firstDecision = try store.apply(revocation)
        let firstState = store.stored
        let firstAck = store.acknowledgement()
        let secondDecision = try store.apply(revocation)

        XCTAssertEqual(firstDecision, .revoke)
        XCTAssertEqual(secondDecision, .revoke)
        XCTAssertEqual(store.stored, firstState)
        XCTAssertEqual(store.acknowledgement(), firstAck)
        XCTAssertFalse(store.hasToken)
        XCTAssertEqual(store.acknowledgement()?.status, .revoked)
    }

    func testRevokedCredentialCannotBeResurrectedAtSameEpoch() throws {
        let suite = "WatchCredentialTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let tokens = InMemoryTokenStore()
        let store = WatchCredentialStore(defaults: defaults, tokens: tokens)
        _ = try store.apply(context(epoch: 2, token: "watch-token"))
        _ = try store.apply(context(epoch: 2, token: nil, status: .revoked))
        let revokedState = store.stored

        XCTAssertEqual(
            try store.apply(context(epoch: 2, configVersion: 4, token: "new-token")),
            .ignoreAndReack
        )
        XCTAssertEqual(store.stored, revokedState)
        XCTAssertFalse(store.hasToken)
        XCTAssertEqual(store.acknowledgement()?.status, .revoked)
    }

    func testNewDeviceLineageMayStartBelowRevokedEpoch() {
        let revoked = stored(deviceID: "watch-a", epoch: 9, revoked: true)
        XCTAssertEqual(
            WatchCredentialPolicy.decision(
                for: context(
                    epoch: 1, token: "new-token", deviceID: "watch-b"
                ),
                stored: revoked,
                hasToken: false
            ),
            .applyToken
        )
        XCTAssertEqual(
            WatchCredentialPolicy.decision(
                for: context(epoch: 1, token: nil, deviceID: "watch-b"),
                stored: revoked,
                hasToken: false
            ),
            .ignoreAndReack
        )
        XCTAssertEqual(
            WatchCredentialPolicy.decision(
                for: context(epoch: 9, token: "same-token", deviceID: "watch-a"),
                stored: revoked,
                hasToken: false
            ),
            .ignoreAndReack
        )
        XCTAssertEqual(
            WatchCredentialPolicy.decision(
                for: context(epoch: 10, token: "newer-token", deviceID: "watch-a"),
                stored: revoked,
                hasToken: false
            ),
            .applyToken
        )
    }

    func testStoreAcceptsNewDeviceLineageButRejectsStaleLineageIdentity() throws {
        let suite = "WatchCredentialTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let tokens = InMemoryTokenStore()
        let store = WatchCredentialStore(defaults: defaults, tokens: tokens)
        _ = try store.apply(context(epoch: 9, token: "revoked-token", deviceID: "watch-a"))
        _ = try store.apply(context(
            epoch: 9, token: nil, status: .revoked, deviceID: "watch-a"
        ))
        let revokedState = store.stored

        XCTAssertEqual(
            try store.apply(context(epoch: 1, token: nil, deviceID: "watch-b")),
            .ignoreAndReack
        )
        XCTAssertEqual(store.stored, revokedState)
        XCTAssertFalse(store.hasToken)
        XCTAssertEqual(store.acknowledgement()?.status, .revoked)

        XCTAssertEqual(
            try store.apply(context(epoch: 1, token: "lineage-b", deviceID: "watch-b")),
            .applyToken
        )
        XCTAssertEqual(store.stored?.deviceID, "watch-b")
        XCTAssertEqual(store.stored?.epoch, 1)
        XCTAssertEqual(store.loadToken(), "lineage-b")
        XCTAssertEqual(store.acknowledgement()?.status, .ready)
    }

    func testTokenlessProbePolicyOnlyAdoptsWhenNoCredentialExists() {
        let noToken = stored(epoch: 1)
        XCTAssertEqual(
            WatchCredentialPolicy.decision(
                for: context(epoch: 2, token: nil),
                stored: noToken, hasToken: false
            ),
            .adoptMissingProbe
        )

        let validToken = stored(epoch: 1)
        XCTAssertEqual(
            WatchCredentialPolicy.decision(
                for: context(epoch: 2, token: nil),
                stored: validToken, hasToken: true
            ),
            .ignoreAndReack
        )

        let revoked = stored(epoch: 1, revoked: true)
        XCTAssertEqual(
            WatchCredentialPolicy.decision(
                for: context(epoch: 1, token: nil),
                stored: revoked, hasToken: false
            ),
            .ignoreAndReack
        )
    }

    func testTokenlessProbeWithNoCredentialAdoptsMetadataAndAcksMissing() throws {
        let suite = "WatchCredentialTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchCredentialStore(defaults: defaults, tokens: InMemoryTokenStore())

        XCTAssertEqual(
            try store.apply(context(epoch: 3, configVersion: 5, token: nil)),
            .adoptMissingProbe
        )
        XCTAssertEqual(store.stored?.deviceID, "watch-1")
        XCTAssertEqual(store.stored?.epoch, 3)
        XCTAssertFalse(store.hasToken)
        let ack = store.acknowledgement()
        XCTAssertEqual(ack?.deviceID, "watch-1")
        XCTAssertEqual(ack?.ackEpoch, 3)
        XCTAssertEqual(ack?.status, .missing)
    }

    func testTokenlessProbeReplacesStaleDifferentDeviceWhenNoTokenExists() throws {
        let suite = "WatchCredentialTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchCredentialStore(defaults: defaults, tokens: InMemoryTokenStore())
        _ = try store.apply(context(epoch: 1, token: "old-token", deviceID: "watch-a"))
        store.markCredentialsMissing()

        XCTAssertEqual(
            try store.apply(context(epoch: 2, token: nil, deviceID: "watch-b")),
            .adoptMissingProbe
        )
        XCTAssertEqual(store.stored?.deviceID, "watch-b")
        XCTAssertEqual(store.stored?.epoch, 2)
        XCTAssertFalse(store.hasToken)
        XCTAssertEqual(store.acknowledgement()?.deviceID, "watch-b")
        XCTAssertEqual(store.acknowledgement()?.ackEpoch, 2)
        XCTAssertEqual(store.acknowledgement()?.status, .missing)
    }

    func testTokenlessProbeReplacesOlderEpochOfSameDeviceWhenNoTokenExists() throws {
        let suite = "WatchCredentialTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchCredentialStore(defaults: defaults, tokens: InMemoryTokenStore())
        _ = try store.apply(context(epoch: 1, token: "old-token"))
        store.markCredentialsMissing()

        XCTAssertEqual(
            try store.apply(context(epoch: 2, token: nil)),
            .adoptMissingProbe
        )
        XCTAssertEqual(store.stored?.epoch, 2)
        XCTAssertFalse(store.hasToken)
        XCTAssertEqual(store.acknowledgement()?.ackEpoch, 2)
        XCTAssertEqual(store.acknowledgement()?.status, .missing)
    }

    func testTokenlessProbePreservesValidCredentialAndDifferentIdentity() throws {
        let suite = "WatchCredentialTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchCredentialStore(defaults: defaults, tokens: InMemoryTokenStore())
        _ = try store.apply(context(epoch: 1, token: "valid-token", deviceID: "watch-a"))
        let before = store.stored

        XCTAssertEqual(
            try store.apply(context(epoch: 2, token: nil, deviceID: "watch-b")),
            .ignoreAndReack
        )
        XCTAssertEqual(store.loadToken(), "valid-token")
        XCTAssertEqual(store.stored, before)
        let ack = store.acknowledgement()
        XCTAssertEqual(ack?.deviceID, "watch-a")
        XCTAssertEqual(ack?.ackEpoch, 1)
        XCTAssertEqual(ack?.status, .ready)
    }

    func testTokenlessProbeDoesNotResurrectRevokedMetadataAtSameEpoch() throws {
        let suite = "WatchCredentialTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchCredentialStore(defaults: defaults, tokens: InMemoryTokenStore())
        _ = try store.apply(context(epoch: 2, token: "watch-token"))
        _ = try store.apply(context(epoch: 2, token: nil, status: .revoked))
        let revokedState = store.stored

        XCTAssertEqual(
            try store.apply(context(epoch: 2, configVersion: 4, token: nil)),
            .ignoreAndReack
        )
        XCTAssertEqual(store.stored, revokedState)
        XCTAssertFalse(store.hasToken)
        XCTAssertEqual(store.acknowledgement()?.status, .revoked)
    }

    func testTokenlessProbeDoesNotReplaceNewerMetadataWithAnOlderProbe() throws {
        let suite = "WatchCredentialTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchCredentialStore(defaults: defaults, tokens: InMemoryTokenStore())
        _ = try store.apply(context(epoch: 3, token: nil))

        XCTAssertEqual(
            try store.apply(context(epoch: 2, token: nil)),
            .ignoreAndReack
        )
        XCTAssertEqual(store.stored?.epoch, 3)
        XCTAssertEqual(store.acknowledgement()?.ackEpoch, 3)
        XCTAssertEqual(store.acknowledgement()?.status, .missing)
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
            .adoptMissingProbe
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
