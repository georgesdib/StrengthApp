import Foundation

/// One watch operation relayed through the phone. The watch token and the watch's original
/// operation id travel with the request so the server's ownership and idempotency checks see the
/// watch as the execution device and a retry cannot duplicate a write.
public enum WatchRelayOperation: String, Codable, Sendable {
    case bootstrap
    case start
    case addSet
    case executionEvents
    case finish
    case abandon
    case rateForm
}

public struct WatchRelayRequest: Codable, Sendable {
    public let requestId: String
    public let operation: WatchRelayOperation
    public let baseURL: String
    public let token: String
    public let deviceID: String?
    public let workoutId: String?
    public let issuedPlanId: String?
    public let idempotencyKey: String?
    /// The JSON-encoded request body, when the operation has one.
    public let payload: Data?

    public init(
        requestId: String = UUID().uuidString.lowercased(),
        operation: WatchRelayOperation,
        baseURL: String,
        token: String,
        deviceID: String?,
        workoutId: String? = nil,
        issuedPlanId: String? = nil,
        idempotencyKey: String? = nil,
        payload: Data? = nil
    ) {
        self.requestId = requestId
        self.operation = operation
        self.baseURL = baseURL
        self.token = token
        self.deviceID = deviceID
        self.workoutId = workoutId
        self.issuedPlanId = issuedPlanId
        self.idempotencyKey = idempotencyKey
        self.payload = payload
    }
}

public struct WatchRelayResponse: Codable, Sendable {
    public let requestId: String
    public let ok: Bool
    /// The JSON-encoded response body from the server.
    public let payload: Data?
    public let errorMessage: String?

    public init(
        requestId: String,
        ok: Bool,
        payload: Data? = nil,
        errorMessage: String? = nil
    ) {
        self.requestId = requestId
        self.ok = ok
        self.payload = payload
        self.errorMessage = errorMessage
    }
}

public protocol WatchRelayTransport: AnyObject {
    func send(_ request: WatchRelayRequest) async throws -> WatchRelayResponse
}

public enum WatchRelayCoding {
    public static func encodeRequest(_ request: WatchRelayRequest) -> String? {
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decodeRequest(_ value: String) -> WatchRelayRequest? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WatchRelayRequest.self, from: data)
    }

    public static func encodeResponse(_ response: WatchRelayResponse) -> String? {
        guard let data = try? JSONEncoder().encode(response) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decodeResponse(_ value: String) -> WatchRelayResponse? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WatchRelayResponse.self, from: data)
    }
}

