import Foundation

/// The versioned WatchConnectivity credential state exchanged between the iPhone and watch.
///
/// The token is optional so a config-only refresh can be sent after the phone has cleared the
/// token. A new epoch always carries a token; a same-epoch higher configVersion does not.
public enum WatchCredentialSchema {
    public static let version = 1
}

public enum WatchCredentialStatus: String, Codable, Equatable, Sendable {
    case ready
    case missing
    case revoked
}

public enum WatchCredentialError: LocalizedError, Equatable {
    case unsupportedSchema
    case invalidField(String)
    case invalidStatus

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema:
            return "The Apple Watch credential has an unsupported version."
        case .invalidField(let name):
            return "The Apple Watch credential has an invalid \(name)."
        case .invalidStatus:
            return "The Apple Watch credential has an unknown status."
        }
    }
}

public struct WatchCredentialContext: Equatable, Sendable {
    public let schema: Int
    public let epoch: Int
    public let configVersion: Int
    public let homeBaseURL: String
    public let deviceID: String
    public let token: String?
    public let issuedAt: String
    public let status: WatchCredentialStatus

    public init(
        schema: Int = WatchCredentialSchema.version,
        epoch: Int,
        configVersion: Int,
        homeBaseURL: String,
        deviceID: String,
        token: String?,
        issuedAt: String,
        status: WatchCredentialStatus = .ready
    ) {
        self.schema = schema
        self.epoch = epoch
        self.configVersion = configVersion
        self.homeBaseURL = homeBaseURL
        self.deviceID = deviceID
        self.token = token
        self.issuedAt = issuedAt
        self.status = status
    }

    public init(dictionary: [String: Any]) throws {
        guard let schema = Self.int(dictionary["schema"]) else {
            throw WatchCredentialError.invalidField("schema")
        }
        guard schema == WatchCredentialSchema.version else {
            throw WatchCredentialError.unsupportedSchema
        }
        guard let epoch = Self.int(dictionary["epoch"]) else {
            throw WatchCredentialError.invalidField("epoch")
        }
        guard let configVersion = Self.int(dictionary["configVersion"]) else {
            throw WatchCredentialError.invalidField("configVersion")
        }
        guard let homeBaseURL = dictionary["homeBaseURL"] as? String else {
            throw WatchCredentialError.invalidField("homeBaseURL")
        }
        guard let deviceID = dictionary["deviceID"] as? String else {
            throw WatchCredentialError.invalidField("deviceID")
        }
        guard let issuedAt = dictionary["issuedAt"] as? String else {
            throw WatchCredentialError.invalidField("issuedAt")
        }
        guard let statusRaw = dictionary["status"] as? String,
              let status = WatchCredentialStatus(rawValue: statusRaw) else {
            throw WatchCredentialError.invalidStatus
        }
        let token = dictionary["token"] as? String
        self.init(
            schema: schema,
            epoch: epoch,
            configVersion: configVersion,
            homeBaseURL: homeBaseURL,
            deviceID: deviceID,
            token: token,
            issuedAt: issuedAt,
            status: status
        )
    }

    public func validated() throws -> WatchCredentialContext {
        guard schema == WatchCredentialSchema.version else {
            throw WatchCredentialError.unsupportedSchema
        }
        guard epoch > 0 else {
            throw WatchCredentialError.invalidField("epoch")
        }
        guard configVersion > 0 else {
            throw WatchCredentialError.invalidField("configVersion")
        }
        guard !deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WatchCredentialError.invalidField("deviceID")
        }
        guard !issuedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WatchCredentialError.invalidField("issuedAt")
        }
        _ = try IOSAPIClient.validatedBaseURL(homeBaseURL)
        if let token, token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw WatchCredentialError.invalidField("token")
        }
        if status == .revoked, token != nil {
            throw WatchCredentialError.invalidField("token")
        }
        return self
    }

    public var dictionary: [String: Any] {
        var value: [String: Any] = [
            "schema": schema,
            "epoch": epoch,
            "configVersion": configVersion,
            "homeBaseURL": homeBaseURL,
            "deviceID": deviceID,
            "issuedAt": issuedAt,
            "status": status.rawValue,
        ]
        if let token {
            value["token"] = token
        }
        return value
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return nil
    }
}

public struct WatchAcknowledgement: Equatable, Sendable {
    public let schema: Int
    public let ackEpoch: Int
    public let configVersion: Int
    public let deviceID: String
    public let status: WatchCredentialStatus

    public init(
        schema: Int = WatchCredentialSchema.version,
        ackEpoch: Int,
        configVersion: Int,
        deviceID: String,
        status: WatchCredentialStatus
    ) {
        self.schema = schema
        self.ackEpoch = ackEpoch
        self.configVersion = configVersion
        self.deviceID = deviceID
        self.status = status
    }

    public init(dictionary: [String: Any]) throws {
        guard let schema = Self.int(dictionary["schema"]) else {
            throw WatchCredentialError.invalidField("schema")
        }
        guard schema == WatchCredentialSchema.version else {
            throw WatchCredentialError.unsupportedSchema
        }
        guard let ackEpoch = Self.int(dictionary["ackEpoch"]) else {
            throw WatchCredentialError.invalidField("ackEpoch")
        }
        guard let configVersion = Self.int(dictionary["configVersion"]) else {
            throw WatchCredentialError.invalidField("configVersion")
        }
        guard let deviceID = dictionary["deviceID"] as? String,
              !deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WatchCredentialError.invalidField("deviceID")
        }
        guard let statusRaw = dictionary["status"] as? String,
              let status = WatchCredentialStatus(rawValue: statusRaw) else {
            throw WatchCredentialError.invalidStatus
        }
        self.init(
            schema: schema,
            ackEpoch: ackEpoch,
            configVersion: configVersion,
            deviceID: deviceID,
            status: status
        )
    }

    public var dictionary: [String: Any] {
        [
            "schema": schema,
            "ackEpoch": ackEpoch,
            "configVersion": configVersion,
            "deviceID": deviceID,
            "status": status.rawValue,
        ]
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return nil
    }
}

public struct WatchStoredCredential: Codable, Equatable, Sendable {
    public var deviceID: String
    public var epoch: Int
    public var configVersion: Int
    public var homeBaseURL: String
    public var lastAckAt: String?
    public var revoked: Bool

    public init(
        deviceID: String,
        epoch: Int,
        configVersion: Int,
        homeBaseURL: String,
        lastAckAt: String? = nil,
        revoked: Bool = false
    ) {
        self.deviceID = deviceID
        self.epoch = epoch
        self.configVersion = configVersion
        self.homeBaseURL = homeBaseURL
        self.lastAckAt = lastAckAt
        self.revoked = revoked
    }
}

public enum WatchCredentialDecision: Equatable, Sendable {
    case applyToken
    case applyConfiguration
    case ignoreAndReack
    case adoptMissingProbe
    case revoke
}

public enum WatchCredentialPolicy {
    /// The watch accepts a new epoch, or a same-epoch higher configVersion. A duplicate is
    /// ignored but re-acked; a revoked credential cannot be resurrected at the same epoch.
    ///
    /// A tokenless probe is metadata only. It may replace metadata that has no token (or no
    /// metadata at all), so a reinstalled or stale watch can report the phone's current identity
    /// as missing and trigger a fresh mint. It never replaces a still-valid token or a revoked
    /// credential, and it never grants authenticated access.
    public static func decision(
        for context: WatchCredentialContext,
        stored: WatchStoredCredential?,
        hasToken: Bool
    ) -> WatchCredentialDecision {
        if context.status == .revoked {
            guard let stored else { return .revoke }
            // A revocation for another device must not revoke this device's credential.
            guard context.deviceID == stored.deviceID else {
                return .ignoreAndReack
            }
            return context.epoch >= stored.epoch ? .revoke : .ignoreAndReack
        }
        guard let stored else {
            return context.token == nil ? .adoptMissingProbe : .applyToken
        }
        if stored.revoked {
            // Only a real new-epoch token can replace a revoked credential.
            if context.epoch > stored.epoch, context.token != nil {
                return .applyToken
            }
            return .ignoreAndReack
        }
        if context.epoch < stored.epoch {
            return .ignoreAndReack
        }
        if context.epoch == stored.epoch {
            if context.deviceID != stored.deviceID {
                // A tokenless probe may replace metadata only when there is no token to
                // preserve. A token-bearing context at the same epoch is not a valid rotation.
                if context.token == nil, !hasToken {
                    return .adoptMissingProbe
                }
                return .ignoreAndReack
            }
            guard context.configVersion > stored.configVersion else {
                return .ignoreAndReack
            }
            return context.token == nil ? .applyConfiguration : .applyToken
        }
        // A newer epoch with a token is a real credential. Without a token it can only clear
        // metadata that has no credential; a valid token is preserved for the phone to replace.
        if context.token != nil {
            return .applyToken
        }
        return hasToken ? .ignoreAndReack : .adoptMissingProbe
    }
}
