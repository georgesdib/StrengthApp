import Foundation

// MARK: - Watch devices

public struct WatchDevice: Decodable, Equatable, Sendable {
    public let deviceId: String
    public let label: String
    public let kind: String
    public let parentDeviceId: String?
    public let credentialEpoch: Int?
    public let createdAt: String?
    public let lastSeenAt: String?
    public let revokedAt: String?

    public init(
        deviceId: String,
        label: String,
        kind: String,
        parentDeviceId: String? = nil,
        credentialEpoch: Int? = nil,
        createdAt: String? = nil,
        lastSeenAt: String? = nil,
        revokedAt: String? = nil
    ) {
        self.deviceId = deviceId
        self.label = label
        self.kind = kind
        self.parentDeviceId = parentDeviceId
        self.credentialEpoch = credentialEpoch
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.revokedAt = revokedAt
    }
}

public struct WatchMintResponse: Decodable, Equatable, Sendable {
    public let device: WatchDevice
    public let token: String
    public let createdAt: String
    public let replacedDeviceId: String?

    public init(
        device: WatchDevice,
        token: String,
        createdAt: String,
        replacedDeviceId: String? = nil
    ) {
        self.device = device
        self.token = token
        self.createdAt = createdAt
        self.replacedDeviceId = replacedDeviceId
    }
}

public struct DeviceListResponse: Decodable, Equatable, Sendable {
    public let devices: [WatchDevice]

    public init(devices: [WatchDevice]) {
        self.devices = devices
    }
}

public struct DeviceRevokeResponse: Decodable, Equatable, Sendable {
    public let deviceId: String
    public let revokedAt: String?
    public let alreadyRevoked: Bool
    public let revokedWatchIds: [String]?

    public init(
        deviceId: String,
        revokedAt: String? = nil,
        alreadyRevoked: Bool,
        revokedWatchIds: [String]? = nil
    ) {
        self.deviceId = deviceId
        self.revokedAt = revokedAt
        self.alreadyRevoked = alreadyRevoked
        self.revokedWatchIds = revokedWatchIds
    }
}
