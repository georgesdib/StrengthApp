import Foundation

/// One watch operation relayed through the phone. The watch token and the watch's original
/// operation id travel with the request so the server's ownership and idempotency checks see the
/// watch as the execution device and a retry cannot duplicate a write.
public enum WatchRelayOperation: String, Codable, Sendable {
    case bootstrap
    case start
    case addSet
    case updateSet
    case removeSet
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

/// A small status heartbeat from the watch. The phone uses it to name the watch in
/// `pending_devices` when it finishes, and to avoid leaving a reconciliation window open after
/// the watch has already sent everything.
public struct WatchWorkoutStatus: Codable, Equatable, Sendable {
    public let workoutId: String?
    public let sessionId: String?
    public let pendingCount: Int
    public let phase: String
    public let finishAcknowledged: Bool
    /// The watch app's build stamp. The Watch app's install handoff is silent, so without this
    /// the phone has no way to name the build actually installed on the wrist. Optional: a watch
    /// built before the stamp existed simply omits it.
    public let build: String?
    public let updatedAt: String

    public init(
        workoutId: String?,
        sessionId: String?,
        pendingCount: Int,
        phase: String,
        finishAcknowledged: Bool,
        build: String? = nil,
        updatedAt: String = ExecutionEvent.nowISO()
    ) {
        self.workoutId = workoutId
        self.sessionId = sessionId
        self.pendingCount = pendingCount
        self.phase = phase
        self.finishAcknowledged = finishAcknowledged
        self.build = build
        self.updatedAt = updatedAt
    }

    public var message: [String: Any]? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return ["watch_status": String(decoding: data, as: UTF8.self)]
    }

    public static func decode(_ userInfo: [String: Any]) -> WatchWorkoutStatus? {
        guard let value = userInfo["watch_status"] as? String,
              let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WatchWorkoutStatus.self, from: data)
    }

    /// True once the watch's session is over on the server, so the phone may close its workout
    /// card. A watch that is still finishing or flushing sets keeps the card alive.
    public var sessionEnded: Bool {
        guard workoutId != nil else { return false }
        if finishAcknowledged { return true }
        let value = phase.lowercased()
        return value == "finished" || value == "abandoned" || value.hasPrefix("ended")
    }

    /// True while this watch could still have unsent work for the given workout.
    public func hasPendingWork(for workoutId: String?) -> Bool {
        guard let workoutId, self.workoutId == workoutId else { return false }
        if finishAcknowledged && pendingCount == 0 { return false }
        return pendingCount > 0 || phase == "active" || phase == "finishing"
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

