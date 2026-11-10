import Foundation

/// The watch's credential store. The token is the only secret and stays in the Watch Keychain;
/// the non-secret epoch/config/URL metadata stays in UserDefaults.
public final class WatchCredentialStore {
    public static let keychainService = "com.georgesdibpersonalteam.StrengthApp.watch"
    public static let keychainAccount = "api-token"

    private let defaults: UserDefaults
    private let tokens: TokenStoring
    private let metadataKey = "ios.watch.credential"

    public init(
        defaults: UserDefaults = .standard,
        tokens: TokenStoring = KeychainTokenStore(
            service: WatchCredentialStore.keychainService,
            account: WatchCredentialStore.keychainAccount
        )
    ) {
        self.defaults = defaults
        self.tokens = tokens
    }

    public var stored: WatchStoredCredential? {
        guard let data = defaults.data(forKey: metadataKey) else { return nil }
        return try? JSONDecoder().decode(WatchStoredCredential.self, from: data)
    }

    public var hasToken: Bool { tokens.load() != nil }

    public func loadToken() -> String? { tokens.load() }

    /// Apply a validated context using the shared epoch/configVersion policy.
    @discardableResult
    public func apply(_ context: WatchCredentialContext) throws -> WatchCredentialDecision {
        let context = try context.validated()
        let decision = WatchCredentialPolicy.decision(
            for: context, stored: stored, hasToken: hasToken
        )
        switch decision {
        case .applyToken:
            guard let token = context.token, !token.isEmpty else {
                throw WatchCredentialError.invalidField("token")
            }
            try tokens.save(token)
            save(WatchStoredCredential(
                deviceID: context.deviceID,
                epoch: context.epoch,
                configVersion: context.configVersion,
                homeBaseURL: context.homeBaseURL,
                lastAckAt: stored?.lastAckAt,
                revoked: false
            ))
        case .applyConfiguration:
            guard var next = stored else {
                throw WatchCredentialError.invalidField("credential")
            }
            if let token = context.token, !token.isEmpty {
                try tokens.save(token)
            }
            next.homeBaseURL = context.homeBaseURL
            next.configVersion = context.configVersion
            next.revoked = false
            save(next)
        case .revoke:
            tokens.delete()
            if var next = stored {
                next.revoked = true
                next.epoch = max(next.epoch, context.epoch)
                next.configVersion = max(next.configVersion, context.configVersion)
                save(next)
            } else {
                save(WatchStoredCredential(
                    deviceID: context.deviceID,
                    epoch: context.epoch,
                    configVersion: context.configVersion,
                    homeBaseURL: context.homeBaseURL,
                    lastAckAt: nil,
                    revoked: true
                ))
            }
        case .adoptMissingProbe:
            // A probe is metadata only. Replace stale, tokenless metadata with the phone's
            // current identity so the acknowledgement names the state we actually hold. A
            // token is deliberately absent; the phone must mint a new epoch to grant access.
            tokens.delete()
            save(WatchStoredCredential(
                deviceID: context.deviceID,
                epoch: context.epoch,
                configVersion: context.configVersion,
                homeBaseURL: context.homeBaseURL,
                lastAckAt: nil,
                revoked: false
            ))
        case .ignoreAndReack:
            break
        }
        return decision
    }

    /// The acknowledgement the watch sends after applying (or ignoring) a context.
    public func acknowledgement() -> WatchAcknowledgement? {
        guard let stored else { return nil }
        let status: WatchCredentialStatus
        if stored.revoked {
            status = .revoked
        } else if hasToken {
            status = .ready
        } else {
            status = .missing
        }
        return WatchAcknowledgement(
            ackEpoch: stored.epoch,
            configVersion: stored.configVersion,
            deviceID: stored.deviceID,
            status: status
        )
    }

    public func markAcknowledged(at date: Date = Date()) {
        guard var next = stored else { return }
        next.lastAckAt = ISO8601DateFormatter().string(from: date)
        save(next)
    }

    public func markCredentialsMissing() {
        tokens.delete()
    }

    public func clear() {
        tokens.delete()
        defaults.removeObject(forKey: metadataKey)
    }

    private func save(_ value: WatchStoredCredential) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: metadataKey)
    }
}
