import Foundation

/// One paired server session: the base URL the owner entered and the Keychain-held token.
public struct IOSSession: Equatable {
    public let baseURL: URL
    public let token: String
    public let deviceID: String?

    public init(baseURL: URL, token: String, deviceID: String? = nil) {
        self.baseURL = baseURL
        self.token = token
        self.deviceID = deviceID
    }
}

public enum APIError: LocalizedError, Equatable {
    case invalidBaseURL(String)
    case invalidPairingCode
    case invalidLabel(String)
    case transport(String)
    case http(status: Int, message: String, fields: [String: String])
    case server(status: Int, code: String, message: String, fields: [String: String], details: [String: JSONValue])
    case journal(String)
    case unauthorized
    case forbidden
    case decoding

    /// True only for a connection-level failure, which is the one case the phone relay may
    /// safely retry; a server rejection must be surfaced unchanged.
    public var isTransport: Bool {
        if case .transport = self { return true }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let message):
            return message
        case .invalidPairingCode:
            return "Enter the 8-digit code printed by strength-coach ios pair."
        case .invalidLabel(let message):
            return message
        case .transport(let message):
            return message.isEmpty
                ? "Could not reach the server. Check that it is running and that this iPhone is on the same network."
                : message
        case .http(let status, let message, let fields):
            return Self.httpDescription(status: status, message: message, fields: fields)
        case .server(let status, _, let message, let fields, _):
            return Self.httpDescription(status: status, message: message, fields: fields)
        case .journal(let message):
            return message
        case .unauthorized, .forbidden:
            return "This device is no longer paired. Pair it again."
        case .decoding:
            return "The server response could not be read."
        }
    }

    public static func httpDescription(status: Int, message: String,
                                fields: [String: String]) -> String {
        if (500...599).contains(status) {
            return "The server could not complete the request (HTTP \(status))."
        }
        if let field = fields.sorted(by: { $0.key < $1.key }).first {
            return "\(message) (\(field.key): \(field.value))"
        }
        return message
    }

    public var isAuthenticationFailure: Bool {
        switch self {
        case .unauthorized, .forbidden: return true
        default: return false
        }
    }

    public var code: String? {
        if case .server(_, let code, _, _, _) = self { return code }
        return nil
    }

    /// Field-specific validation messages. The readiness form attaches these to the matching
    /// input instead of showing one opaque banner.
    public var fields: [String: String] {
        switch self {
        case .http(_, _, let fields), .server(_, _, _, let fields, _):
            return fields
        default:
            return [:]
        }
    }

    public var details: [String: JSONValue]? {
        if case .server(_, _, _, _, let details) = self { return details }
        return nil
    }
}

// MARK: - Transport

@MainActor
public protocol HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// A GET-only transport with no cookies or shared cache. Redirects are allowed only within the
/// original origin (scheme, host and port) so the bearer token can never follow a redirect to
/// another server, port or HTTP/HTTPS scheme.
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 10) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 2
        let guardDelegate = SameHostRedirectGuard()
        self.session = URLSession(
            configuration: configuration,
            delegate: guardDelegate,
            delegateQueue: nil
        )
    }

    @MainActor
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport("The server returned a non-HTTP response.")
        }
        return (data, http)
    }
}

/// The redirect policy compares the full origin, not just the hostname.
///
/// A hostname-only check would allow http://host:8000 to redirect to http://host:9000 or
/// https://host, forwarding the bearer token to a different server or scheme. The guard compares
/// the original request's origin with the redirect target's origin: same scheme
/// (case-insensitive), same host (case-insensitive) and same effective port.
public nonisolated enum RedirectPolicy {
    public struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int
    }

    public static func origin(of url: URL?) -> Origin? {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty,
              url.user == nil,
              url.password == nil else {
            return nil
        }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return Origin(scheme: scheme, host: host, port: port)
    }

    public static func allowsRedirect(from original: URL?, to target: URL?) -> Bool {
        guard let originalOrigin = origin(of: original),
              let targetOrigin = origin(of: target) else {
            return false
        }
        return originalOrigin == targetOrigin
    }
}

/// Kept as SameHostRedirectGuard because that is the transport-level name, but the policy is
/// same-origin: a cross-port or scheme-changing redirect is rejected and never receives the
/// Authorization header.
public final class SameHostRedirectGuard: NSObject, URLSessionTaskDelegate {
    public nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(
            RedirectPolicy.allowsRedirect(
                from: task.originalRequest?.url,
                to: request.url
            ) ? request : nil
        )
    }
}

/// User-facing wording for transport failures whose system text names the rule but not the fix.
///
/// The cleartext case is the one that misleads: iOS says the resource "could not be loaded
/// because the App Transport Security policy requires the use of a secure connection", which reads
/// like a server fault. It is a client policy refusal, and the remedy is in the address.
extension URLError.Code {
    var clientFacingMessage: String? {
        switch self {
        case .appTransportSecurityRequiresSecureConnection:
            return "iOS refuses plain http:// to this address. Use https://, or a private-network "
                + "address (192.168.x.x, 10.x.x.x), a .local name or a single-word host name."
        default:
            return nil
        }
    }
}

/// Why a Home/Away probe succeeded or failed. Routing only needs `isReachable`, but the Settings
/// screen explains the reason, so a blocked address is not reported as an offline server.
public enum ServerProbeResult: Equatable, Sendable {
    case reachable
    /// The server answered but refused this device credential. Reachable: switching route
    /// cannot fix a stale token, so routing still treats it as up.
    case unauthorized
    /// iOS refused the address itself (cleartext http to a host App Transport Security does not
    /// treat as local). Nothing was sent, and no retry will help.
    case blockedByPolicy
    case serverError(status: Int)
    case unreachable

    /// Routing keeps the pre-existing rule: only a 2xx/4xx answer counts as up. A 5xx still
    /// falls through to the Away Server, which is why `serverError` is reported separately.
    public var isReachable: Bool {
        switch self {
        case .reachable, .unauthorized: return true
        case .serverError, .blockedByPolicy, .unreachable: return false
        }
    }
}
private struct TransportFailure: Error {
    let code: URLError.Code
    let message: String

    var isTransient: Bool {
        switch code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable:
            return true
        default:
            return false
        }
    }
}

// MARK: - Client

/// The single Phase 1 API client. All training decisions stay on the server; this type only
/// validates the owner's input, attaches the bearer token and decodes the read payloads.
@MainActor
public final class IOSAPIClient {
    private let transport: HTTPTransport
    private let longTransport: HTTPTransport
    private let decoder: JSONDecoder
    private let encoder = JSONEncoder()
    private let journal: MutationJournal?
    private let maxGETRetries = 2
    /// When set, a transport failure falls back to the paired phone. The direct server path is
    /// always attempted first; a relay is never the only copy.
    public var relay: (any WatchRelayTransport)?
    /// Watch execution writes use the phone as the only committer. Reads still go direct.
    public var requiresPhoneRelay = false

    public init(
        transport: HTTPTransport,
        journal: MutationJournal? = nil,
        longTransport: HTTPTransport? = nil
    ) {
        self.transport = transport
        self.longTransport = longTransport ?? transport
        self.journal = journal
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    public convenience init(journal: MutationJournal? = nil) {
        self.init(
            transport: URLSessionTransport(timeout: 10),
            journal: journal,
            longTransport: URLSessionTransport(timeout: 60)
        )
    }

    /// Relay one operation to the paired phone after the direct path failed at the transport.
    /// The watch token and original idempotency key are preserved so the server sees the watch
    /// as the execution device and a later direct retry cannot duplicate the write.
    private func relayed<T: Decodable>(
        _ operation: WatchRelayOperation,
        session: IOSSession,
        workoutId: String? = nil,
        issuedPlanId: String? = nil,
        idempotencyKey: String? = nil,
        payload: Data? = nil
    ) async throws -> T {
        guard let relay else {
            throw APIError.transport("The server is unreachable and no phone relay is available.")
        }
        let request = WatchRelayRequest(
            operation: operation,
            baseURL: session.baseURL.absoluteString,
            token: session.token,
            deviceID: session.deviceID,
            workoutId: workoutId,
            issuedPlanId: issuedPlanId,
            idempotencyKey: idempotencyKey,
            payload: payload
        )
        let response = try await relay.send(request)
        guard response.ok, let data = response.payload else {
            throw APIError.server(
                status: 400,
                code: "relay_failed",
                message: response.errorMessage ?? "The phone could not relay the request.",
                fields: [:],
                details: [:]
            )
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding
        }
    }

    // MARK: Input validation

    public nonisolated static func validatedBaseURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIError.invalidBaseURL("Enter the server address, for example http://192.168.1.10:8000.")
        }
        guard var components = URLComponents(string: trimmed) else {
            throw APIError.invalidBaseURL("That is not a valid server address.")
        }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw APIError.invalidBaseURL("The server address must start with http:// or https://.")
        }
        guard let host = components.host, !host.isEmpty else {
            throw APIError.invalidBaseURL("The server address needs a host name or IP address.")
        }
        guard components.user == nil, components.password == nil else {
            throw APIError.invalidBaseURL("Do not put a user name or password in the server address.")
        }
        guard components.query == nil, components.fragment == nil else {
            throw APIError.invalidBaseURL("Enter only the server address, without a query or fragment.")
        }
        if components.path == "/" {
            components.path = ""
        } else if components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        guard let url = components.url else {
            throw APIError.invalidBaseURL("That is not a valid server address.")
        }
        return url
    }

    public static func normalizeCode(_ raw: String) throws -> String {
        let cleaned = raw
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard cleaned.count == 8,
              cleaned.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw APIError.invalidPairingCode
        }
        return cleaned
    }

    public static func normalizeLabel(_ raw: String, defaultLabel: String = "iPhone") throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmed.isEmpty ? defaultLabel : trimmed
        guard !label.isEmpty, label.count <= 40 else {
            throw APIError.invalidLabel("The device label must be 1-40 characters.")
        }
        return label
    }

    // MARK: Endpoints

    public func pair(baseURL: URL, code: String, label: String) async throws -> PairResponse {
        let cleanCode = try Self.normalizeCode(code)
        let cleanLabel = try Self.normalizeLabel(label)
        var request = URLRequest(url: baseURL.appendingPathComponent("api/ios/v1/pair"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try encoder.encode(PairRequest(code: cleanCode, label: cleanLabel))
        let (data, response) = try await performNoRetry(request)
        try validate(response, data: data)
        return try decode(PairResponse.self, from: data)
    }

    // MARK: Watch devices

    public func mintWatch(
        session: IOSSession,
        label: String = "Apple Watch"
    ) async throws -> WatchMintResponse {
        let cleanLabel = try Self.normalizeLabel(label, defaultLabel: "Apple Watch")
        var request = URLRequest(url: try url(path: "api/ios/v1/devices/watch", query: [], baseURL: session.baseURL))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try encoder.encode(WatchMintRequest(label: cleanLabel))
        let (data, response) = try await performNoRetry(request)
        try validate(response, data: data)
        return try decode(WatchMintResponse.self, from: data)
    }

    public func devices(session: IOSSession) async throws -> DeviceListResponse {
        try await get(path: "api/ios/v1/devices", query: [], session: session)
    }

    public func revokeDevice(
        deviceId: String,
        session: IOSSession
    ) async throws -> DeviceRevokeResponse {
        var request = URLRequest(
            url: try url(path: "api/ios/v1/devices/\(deviceId)", query: [], baseURL: session.baseURL)
        )
        request.httpMethod = "DELETE"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await performNoRetry(request)
        try validate(response, data: data)
        return try decode(DeviceRevokeResponse.self, from: data)
    }

    public func bootstrap(session: IOSSession) async throws -> BootstrapResponse {
        do {
            return try await get(path: "api/ios/v1/bootstrap", query: [], session: session)
        } catch let error as APIError where error.isTransport {
            guard relay != nil else { throw error }
            return try await relayed(.bootstrap, session: session)
        }
    }

// MARK: - Cardio overview (C6b)

    /// The phone reads the authenticated route, never the browser one.
    public func cardioActivity(
        session: IOSSession,
        weeks: Int = 12,
        includeTimeInZone: Bool = false
    ) async throws -> CardioActivityPayload {
        var query = [URLQueryItem(name: "weeks", value: String(weeks))]
        if includeTimeInZone {
            query.append(URLQueryItem(name: "tiz", value: "true"))
        }
        return try await get(
            path: "api/ios/v1/healthkit/activity/summary",
            query: query,
            session: session
        )
    }

    /// The longevity envelope: the same facts the web panel shows, behind device authentication.
    public func longevity(
        session: IOSSession,
        includeTimeInZone: Bool = false,
        includePatterns: Bool = true
    ) async throws -> IntelligenceEnvelope {
        try await get(
            path: "api/ios/v1/intelligence/longevity",
            query: [
                URLQueryItem(name: "include_time_in_zone", value: includeTimeInZone ? "true" : "false"),
                URLQueryItem(name: "include_patterns", value: includePatterns ? "true" : "false"),
            ],
            session: session
        )
    }

    /// Short, read-only reachability check used for Home/Away selection.
    ///
    /// The reason is kept instead of a bare Bool: "the server is off", "iOS refuses this
    /// address" and "the server answered but rejected this device" are three different problems
    /// with three different fixes, and collapsing them made a blocked Away address look like an
    /// ordinary offline state.
    public func probeServer(baseURL: URL, token: String) async -> ServerProbeResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/ios/v1/bootstrap"))
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await transport.data(for: request)
            switch response.statusCode {
            case 200...299: return .reachable
            case 401, 403: return .unauthorized
            case 400...499: return .reachable
            default: return .serverError(status: response.statusCode)
            }
        } catch let error as URLError
                  where error.code == .appTransportSecurityRequiresSecureConnection {
            return .blockedByPolicy
        } catch {
            return .unreachable
        }
    }

    /// Backwards-compatible reading of the probe: a 401 still proves the server is reachable;
    /// a blocked address and 5xx do not.
    public func isServerReachable(baseURL: URL, token: String) async -> Bool {
        await probeServer(baseURL: baseURL, token: token).isReachable
    }

    public func today(session: IOSSession) async throws -> TodayResponse {
        try await get(path: "api/ios/v1/today", query: [], session: session)
    }

    /// The one AFC-4 review nudge for today, or nil when suppressed or absent.
    public func nudge(session: IOSSession) async throws -> NudgeResponse {
        try await get(path: "api/nudge", query: [], session: session)
    }

    /// Append a dismissal or a 14-day snooze. Not journalled: a nudge decision is a review
    /// record, not a training mutation, and the server is the only owner of the suppression.
    public func recordNudge(
        key: String,
        action: String,
        evidenceId: String?,
        date: String,
        session: IOSSession
    ) async throws -> NudgeResponse {
        struct NudgeDecisionRequest: Encodable {
            let action: String
            let key: String
            let evidenceId: String?
            let date: String
        }
        let body = NudgeDecisionRequest(
            action: action, key: key, evidenceId: evidenceId, date: date
        )
        let request = try makeRequest(
            path: "api/nudge",
            bodyData: try encoder.encode(body),
            session: session,
            idempotencyKey: UUID().uuidString.lowercased()
        )
        let (data, response) = try await performNoRetry(request)
        try validate(response, data: data)
        return try decode(NudgeResponse.self, from: data)
    }

    public func history(session: IOSSession, limit: Int = 50, offset: Int = 0) async throws -> HistoryResponse {
        try await get(
            path: "api/ios/v1/history",
            query: [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset)),
            ],
            session: session
        )
    }

    public func historyDetail(sessionID: String, session: IOSSession) async throws -> HistoryDetail {
        try await get(
            path: "api/ios/v1/history/\(sessionID)",
            query: [],
            session: session
        )
    }

    /// AFC-2i: the authoritative completed-workout summary, unchanged from the web payload.
    public func workoutSummary(
        workoutId: String,
        session: IOSSession
    ) async throws -> WorkoutSummaryEnvelope {
        try await get(
            path: "api/ios/v1/workouts/\(workoutId)/summary",
            query: [],
            session: session,
            timeout: 60,
            transport: longTransport,
            retries: 0
        )
    }

    /// The effective readiness registry schema. The phone form renders from this; the server
    /// remains authoritative for validation and scoring.
    public func readinessSchema(session: IOSSession) async throws -> ReadinessSchema {
        try await get(
            path: "api/ios/v1/readiness/schema",
            query: [],
            session: session
        )
    }

    public func writeReadiness(
        _ body: ReadinessWriteRequest,
        session: IOSSession,
        idempotencyKey: String
    ) async throws -> ReadinessPayload {
        try await post(
            path: "api/ios/v1/readiness",
            body: body,
            kind: .readiness,
            targetId: nil,
            session: session,
            idempotencyKey: idempotencyKey
        )
    }

    public func importHealthKitReadiness(
        _ body: HealthKitReadinessRequest,
        session: IOSSession,
        idempotencyKey: String
    ) async throws -> ReadinessPayload {
        try await post(
            path: "api/ios/v1/healthkit/readiness",
            body: body,
            kind: .healthkitReadiness,
            targetId: nil,
            session: session,
            idempotencyKey: idempotencyKey
        )
    }

    /// Uploads dated recovery-HRV nights. Not journaled: the server deduplicates by sample id,
    /// so a failed page is simply sent again on the next pass.
    public func importRecoveryHRV(
        _ body: RecoveryHRVRequest,
        session: IOSSession,
        idempotencyKey: String
    ) async throws -> RecoveryHRVUploadResult {
        try await post(
            path: "api/ios/v1/healthkit/hrv-recovery",
            body: body,
            kind: .healthkitReadiness,
            targetId: nil,
            session: session,
            idempotencyKey: idempotencyKey,
            journaling: false
        )
    }

// MARK: - HealthKit activity (C2)

    /// Uploads in two calls by design: a sample cannot be attached before its workout exists on the
    /// server. Each call is idempotent on the HealthKit UUID, so a retry costs nothing.
    public func uploadActivity(
        _ body: HealthKitActivityWorkoutsBody,
        session: IOSSession,
        idempotencyKey: String
    ) async throws -> HealthKitActivityUploadResult {
        try await post(
            path: "api/ios/v1/healthkit/workouts",
            body: body,
            kind: .healthkitActivity,
            targetId: nil,
            session: session,
            idempotencyKey: idempotencyKey
        )
    }

    public func uploadActivity(
        _ body: HealthKitActivitySamplesBody,
        session: IOSSession,
        idempotencyKey: String
    ) async throws -> HealthKitActivityUploadResult {
        try await post(
            path: "api/ios/v1/healthkit/samples",
            body: body,
            kind: .healthkitActivity,
            targetId: nil,
            session: session,
            idempotencyKey: idempotencyKey
        )
    }

    /// R7: the request is accepted (202) and the plan is built in the background.
    public func issuePrescription(
        _ body: IssuePrescriptionRequest,
        session: IOSSession,
        idempotencyKey: String
    ) async throws -> PlanRequestAck {
        try await post(
            path: "api/ios/v1/prescriptions",
            body: body,
            kind: .prescription,
            targetId: nil,
            session: session,
            idempotencyKey: idempotencyKey
        )
    }

    public func postponeScheduledDeload(
        _ body: PostponeScheduledDeloadRequest,
        session: IOSSession,
        idempotencyKey: String
    ) async throws -> PostponedScheduledDeloadAck {
        try await post(
            path: "api/ios/v1/deload/postpone",
            body: body,
            kind: .prescription,
            targetId: nil,
            session: session,
            idempotencyKey: idempotencyKey,
            journaling: false
        )
    }

    /// The authoritative plan-request state. Read-only: no idempotency key, no retries beyond
    /// the bounded GET policy.
    public func planState(session: IOSSession) async throws -> PlansStateResponse {
        try await get(path: "api/ios/v1/plans/current", query: [], session: session)
    }

    public func startWorkout(
        issuedPlanId: String,
        executionId: String? = nil,
        startedAt: String? = nil,
        session: IOSSession,
        idempotencyKey: String
    ) async throws -> WorkoutDetail {
        let body = StartWorkoutRequest(
            issuedPlanId: issuedPlanId,
            executionId: executionId,
            startedAt: startedAt
        )
        if requiresPhoneRelay {
            return try await relayed(
                .start,
                session: session,
                issuedPlanId: issuedPlanId,
                idempotencyKey: idempotencyKey,
                payload: try? encoder.encode(body)
            )
        }
        do {
            return try await post(
                path: "api/ios/v1/workouts",
                body: body,
                kind: .startWorkout,
                targetId: issuedPlanId,
                session: session,
                idempotencyKey: idempotencyKey
            )
        } catch let error as APIError where error.isTransport {
            guard relay != nil else { throw error }
            return try await relayed(
                .start,
                session: session,
                issuedPlanId: issuedPlanId,
                idempotencyKey: idempotencyKey,
                payload: try? encoder.encode(body)
            )
        }
    }

    public func addSet(
        workoutId: String,
        body: AddSetRequest,
        session: IOSSession,
        idempotencyKey: String,
        journaling: Bool = true,
        preferRelay: Bool = false
    ) async throws -> WorkoutDetail {
        if requiresPhoneRelay {
            return try await relayed(
                .addSet,
                session: session,
                workoutId: workoutId,
                idempotencyKey: idempotencyKey,
                payload: try? encoder.encode(body)
            )
        }
        // Ack-before-commit: with the phone reachable, the watch commits through it so the phone
        // can merge the index and acknowledge the set. The direct path remains the fallback.
        if preferRelay, relay != nil {
            do {
                return try await relayed(
                    .addSet,
                    session: session,
                    workoutId: workoutId,
                    idempotencyKey: idempotencyKey,
                    payload: try? encoder.encode(body)
                )
            } catch let error as APIError where error.isTransport {
                // The phone stopped answering; the direct path is still available.
            }
        }
        do {
            return try await post(
                path: "api/ios/v1/workouts/\(workoutId)/sets",
                body: body,
                kind: .addSet,
                targetId: workoutId,
                session: session,
                idempotencyKey: idempotencyKey,
                journaling: journaling
            )
        } catch let error as APIError where error.isTransport {
            guard relay != nil else { throw error }
            return try await relayed(
                .addSet,
                session: session,
                workoutId: workoutId,
                idempotencyKey: idempotencyKey,
                payload: try? encoder.encode(body)
            )
        }
    }

    public func submitExecutionEvents(
        workoutId: String,
        events: [ExecutionEvent],
        session: IOSSession,
        idempotencyKey: String
    ) async throws -> ExecutionEventsResponse {
        let body = ExecutionEventsRequest(events: events)
        if requiresPhoneRelay {
            return try await relayed(
                .executionEvents,
                session: session,
                workoutId: workoutId,
                idempotencyKey: idempotencyKey,
                payload: try? encoder.encode(body)
            )
        }
        do {
            return try await post(
                path: "api/ios/v1/workouts/\(workoutId)/execution-events",
                body: body,
                kind: .executionEvents,
                targetId: workoutId,
                session: session,
                idempotencyKey: idempotencyKey,
                journaling: false
            )
        } catch let error as APIError where error.isTransport {
            guard relay != nil else { throw error }
            return try await relayed(
                .executionEvents,
                session: session,
                workoutId: workoutId,
                idempotencyKey: idempotencyKey,
                payload: try? encoder.encode(body)
            )
        }
    }

    public func executionAnalytics(
        workoutId: String,
        session: IOSSession
    ) async throws -> ExecutionAnalyticsResponse {
        try await get(
            path: "api/ios/v1/workouts/\(workoutId)/execution",
            query: [],
            session: session
        )
    }

    /// One correction event; the set keeps its server identity. Never remove-and-re-add.
    public func updateSet(
        workoutId: String,
        body: UpdateSetRequest,
        session: IOSSession,
        idempotencyKey: String
    ) async throws -> WorkoutDetail {
        if requiresPhoneRelay {
            let value: WorkoutDetail = try await relayed(
                .updateSet,
                session: session,
                workoutId: workoutId,
                idempotencyKey: idempotencyKey,
                payload: try? encoder.encode(body)
            )
            return value
        }
        let value: WorkoutDetail = try await post(
            path: "api/ios/v1/workouts/\(workoutId)/update-set",
            body: body,
            kind: .updateSet,
            targetId: workoutId,
            session: session,
            idempotencyKey: idempotencyKey
        )
        return value
    }

    public func removeSet(
        workoutId: String,
        body: RemoveSetRequest,
        session: IOSSession,
        idempotencyKey: String
    ) async throws -> WorkoutDetail {
        if requiresPhoneRelay {
            let value: WorkoutDetail = try await relayed(
                .removeSet,
                session: session,
                workoutId: workoutId,
                idempotencyKey: idempotencyKey,
                payload: try? encoder.encode(body)
            )
            return value
        }
        let value: WorkoutDetail = try await post(
            path: "api/ios/v1/workouts/\(workoutId)/remove-set",
            body: body,
            kind: .removeSet,
            targetId: workoutId,
            session: session,
            idempotencyKey: idempotencyKey
        )
        return value
    }

    public func discardPendingOperation(_ operationId: String) {
        try? journal?.remove(operationId: operationId)
    }

    public func exerciseCatalogue(session: IOSSession) async throws -> ExerciseCatalogueResponse {
        try await get(path: "api/ios/v1/exercises", query: [], session: session)
    }

    public func exerciseDetail(
        exerciseId: String,
        session: IOSSession
    ) async throws -> ExerciseDetailResponse {
        try await get(
            path: "api/ios/v1/exercises/\(exerciseId)",
            query: [],
            session: session
        )
    }

    public func exerciseHistory(
        exerciseId: String,
        limit: Int,
        offset: Int,
        session: IOSSession
    ) async throws -> ExerciseHistoryResponse {
        try await get(
            path: "api/ios/v1/exercises/\(exerciseId)/history",
            query: [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset)),
            ],
            session: session
        )
    }

    /// Appends one phone-authored execution substitution or addition (DEC-RESOLVER-23).
    /// A journaled body keeps the same catalogue value or miss; the server never retro-solves a
    /// catalogue miss.
    public func recordExecutionChange(
        workoutId: String,
        body: ExecutionChangeRequest,
        session: IOSSession,
        idempotencyKey: String,
        journaling: Bool = true
    ) async throws -> ExecutionChangeResponse {
        try await post(
            path: "api/ios/v1/workouts/\(workoutId)/execution",
            body: body,
            kind: .executionChange,
            targetId: workoutId,
            session: session,
            idempotencyKey: idempotencyKey,
            journaling: journaling
        )
    }

    public func rateForm(
        workoutId: String,
        body: FormRatingRequest,
        session: IOSSession,
        idempotencyKey: String,
        journaling: Bool = true
    ) async throws -> WorkoutDetail {
        if requiresPhoneRelay {
            return try await relayed(
                .rateForm,
                session: session,
                workoutId: workoutId,
                idempotencyKey: idempotencyKey,
                payload: try? encoder.encode(body)
            )
        }
        do {
            return try await post(
                path: "api/ios/v1/workouts/\(workoutId)/form",
                body: body,
                kind: .rateForm,
                targetId: workoutId,
                session: session,
                idempotencyKey: idempotencyKey,
                journaling: journaling
            )
        } catch let error as APIError where error.isTransport {
            guard relay != nil else { throw error }
            return try await relayed(
                .rateForm,
                session: session,
                workoutId: workoutId,
                idempotencyKey: idempotencyKey,
                payload: try? encoder.encode(body)
            )
        }
    }

    /// Records that an expected device has nothing left to send. This settles an open
    /// reconciliation window without waiting for its deadline.
    public func reconcileDevice(
        workoutId: String,
        deviceId: String,
        session: IOSSession,
        idempotencyKey: String
    ) async throws -> WorkoutReconciliationResponse {
        try await post(
            path: "api/ios/v1/workouts/\(workoutId)/reconciliation",
            body: ReconciliationDeviceRequest(deviceId: deviceId),
            kind: .reconciliation,
            targetId: workoutId,
            session: session,
            idempotencyKey: idempotencyKey,
            journaling: false
        )
    }

    public func completeWorkout(
        workoutId: String,
        body: CompleteWorkoutRequest,
        session: IOSSession,
        idempotencyKey: String,
        journaling: Bool = true
    ) async throws -> WorkoutDetail {
        if requiresPhoneRelay {
            return try await relayed(
                .finish,
                session: session,
                workoutId: workoutId,
                idempotencyKey: idempotencyKey,
                payload: try? encoder.encode(body)
            )
        }
        do {
            return try await post(
                path: "api/ios/v1/workouts/\(workoutId)/complete",
                body: body,
                kind: .completeWorkout,
                targetId: workoutId,
                session: session,
                idempotencyKey: idempotencyKey,
                journaling: journaling
            )
        } catch let error as APIError where error.isTransport {
            guard relay != nil else { throw error }
            return try await relayed(
                .finish,
                session: session,
                workoutId: workoutId,
                idempotencyKey: idempotencyKey,
                payload: try? encoder.encode(body)
            )
        }
    }

    public func abandonWorkout(
        workoutId: String,
        session: IOSSession,
        idempotencyKey: String
    ) async throws -> WorkoutDetail {
        if requiresPhoneRelay {
            return try await relayed(
                .abandon,
                session: session,
                workoutId: workoutId,
                idempotencyKey: idempotencyKey
            )
        }
        do {
            return try await post(
                path: "api/ios/v1/workouts/\(workoutId)/abandon",
                body: EmptyRequest(),
                kind: .abandonWorkout,
                targetId: workoutId,
                session: session,
                idempotencyKey: idempotencyKey
            )
        } catch let error as APIError where error.isTransport {
            guard relay != nil else { throw error }
            return try await relayed(
                .abandon,
                session: session,
                workoutId: workoutId,
                idempotencyKey: idempotencyKey
            )
        }
    }

    public func progress(
        weeks: Int = 8,
        date: String? = nil,
        session: IOSSession
    ) async throws -> ProgressResponse {
        var query = [URLQueryItem(name: "weeks", value: String(weeks))]
        if let date {
            query.append(URLQueryItem(name: "date", value: date))
        }
        return try await get(
            path: "api/ios/v1/progress",
            query: query,
            session: session
        )
    }

    /// One deterministic weekly-review envelope; `weekEnd` defaults to the last completed week.
    /// Ask the paired server's local project-knowledge Explain endpoint.
    public func explain(
        question: String,
        session: IOSSession
    ) async throws -> ExplainResponse {
        struct Body: Encodable { let question: String }
        return try await post(
            path: "api/intelligence/explain",
            body: Body(question: question),
            kind: .readiness,
            targetId: nil,
            session: session,
            idempotencyKey: UUID().uuidString,
            journaling: false
        )
    }

    public func weeklyReview(
        session: IOSSession,
        weekEnd: String? = nil
    ) async throws -> IntelligenceEnvelope {
        var query: [URLQueryItem] = []
        if let weekEnd {
            query.append(URLQueryItem(name: "week_end", value: weekEnd))
        }
        return try await get(
            path: "api/ios/v1/intelligence/weekly-review",
            query: query,
            session: session
        )
    }


    public func overview(
        session: IOSSession,
        asOf: String? = nil,
        windowWeeks: Int = 4
    ) async throws -> IntelligenceEnvelope {
        var query = [URLQueryItem(name: "window_weeks", value: String(windowWeeks))]
        if let asOf { query.append(URLQueryItem(name: "as_of", value: asOf)) }
        return try await get(
            path: "api/ios/v1/intelligence/overview", query: query, session: session
        )
    }

    public func progression(
        session: IOSSession,
        exerciseID: String,
        windowDays: Int = 84,
        asOf: String? = nil
    ) async throws -> IntelligenceEnvelope {
        var query = [URLQueryItem(name: "window_days", value: String(windowDays))]
        if let asOf { query.append(URLQueryItem(name: "as_of", value: asOf)) }
        return try await get(
            path: "api/ios/v1/intelligence/exercises/\(exerciseID)/progression",
            query: query,
            session: session
        )
    }

    public func readinessHistory(
        session: IOSSession,
        from: String,
        to: String,
        fields: [String]? = nil
    ) async throws -> IntelligenceEnvelope {
        var query = [
            URLQueryItem(name: "from", value: from),
            URLQueryItem(name: "to", value: to),
        ]
        if let fields, !fields.isEmpty {
            query.append(URLQueryItem(name: "fields", value: fields.joined(separator: ",")))
        }
        return try await get(
            path: "api/ios/v1/intelligence/readiness", query: query, session: session
        )
    }

    public func prescription(
        session: IOSSession,
        prescriptionID: String? = nil,
        forDate: String? = nil,
        includeProvenance: Bool = true
    ) async throws -> IntelligenceEnvelope {
        var query = [
            URLQueryItem(name: "include_provenance", value: includeProvenance ? "true" : "false"),
        ]
        if let prescriptionID { query.append(URLQueryItem(name: "prescription_id", value: prescriptionID)) }
        if let forDate { query.append(URLQueryItem(name: "for_date", value: forDate)) }
        return try await get(
            path: "api/ios/v1/intelligence/prescription", query: query, session: session
        )
    }

    public func programmeSummary(
        session: IOSSession,
        asOf: String? = nil,
        blockWeeks: Int = 4
    ) async throws -> IntelligenceEnvelope {
        var query = [URLQueryItem(name: "block_weeks", value: String(blockWeeks))]
        if let asOf { query.append(URLQueryItem(name: "as_of", value: asOf)) }
        return try await get(
            path: "api/ios/v1/intelligence/programme-summary", query: query, session: session
        )
    }

    public func adherence(
        session: IOSSession,
        asOf: String? = nil,
        weeks: Int? = 12
    ) async throws -> IntelligenceEnvelope {
        var query: [URLQueryItem] = []
        if let asOf { query.append(URLQueryItem(name: "as_of", value: asOf)) }
        if let weeks { query.append(URLQueryItem(name: "weeks", value: String(weeks))) }
        query.append(URLQueryItem(name: "group_by", value: "week"))
        return try await get(
            path: "api/ios/v1/intelligence/adherence", query: query, session: session
        )
    }

    public func intelligenceSessionDetails(
        session: IOSSession,
        workoutID: String? = nil,
        sessionID: String? = nil,
        includeRatios: Bool = false
    ) async throws -> IntelligenceEnvelope {
        var query = [URLQueryItem(name: "include_ratios", value: includeRatios ? "true" : "false")]
        if let workoutID { query.append(URLQueryItem(name: "workout_id", value: workoutID)) }
        if let sessionID { query.append(URLQueryItem(name: "session_id", value: sessionID)) }
        return try await get(
            path: "api/ios/v1/intelligence/session-details", query: query, session: session
        )
    }

    // MARK: Pending operations

    public func pendingMutations(for session: IOSSession) -> [PendingMutation] {
        journal?.all(
            for: session.deviceID,
            serverURL: session.baseURL.absoluteString
        ) ?? []
    }

    public func discard(_ entry: PendingMutation) {
        try? journal?.remove(entry)
    }

    public func discardAll(for session: IOSSession) {
        try? journal?.removeAll(
            for: session.deviceID,
            serverURL: session.baseURL.absoluteString
        )
    }

    public func markConflict(_ entry: PendingMutation) {
        try? journal?.markConflict(entry)
    }

    /// Replay a journaled request with its original UUID and exact encoded body.
    public func replay<T: Decodable>(
        _ entry: PendingMutation,
        session: IOSSession
    ) async throws -> T {
        guard entry.serverURL == session.baseURL.absoluteString,
              entry.deviceId == session.deviceID else {
            throw APIError.journal("The pending operation belongs to a different server or device.")
        }
        do {
            let request = try makeRequest(
                path: entry.path,
                bodyData: entry.bodyData,
                session: session,
                idempotencyKey: entry.operationId
            )
            let (data, response) = try await performNoRetry(request)
            try validate(response, data: data)
            try? journal?.acknowledge(entry)
            return try decode(T.self, from: data)
        } catch {
            if let api = error as? APIError {
                handleJournalFailure(api, entry)
            }
            throw error
        }
    }

    // MARK: Requests

    private struct PairRequest: Encodable {
        let code: String
        let label: String
    }

    private struct WatchMintRequest: Encodable {
        let label: String
    }

    private func post<T: Decodable, Body: Encodable>(
        path: String,
        body: Body,
        kind: MutationKind,
        targetId: String?,
        session: IOSSession,
        idempotencyKey: String,
        journaling: Bool = true
    ) async throws -> T {
        let bodyData = try encoder.encode(body)
        return try await send(
            path: path,
            bodyData: bodyData,
            kind: kind,
            targetId: targetId,
            session: session,
            idempotencyKey: idempotencyKey,
            journaling: journaling
        )
    }

    private func send<T: Decodable>(
        path: String,
        bodyData: Data,
        kind: MutationKind,
        targetId: String?,
        session: IOSSession,
        idempotencyKey: String,
        journaling: Bool = true
    ) async throws -> T {
        let entry = PendingMutation(
            operationId: idempotencyKey,
            deviceId: session.deviceID,
            serverURL: session.baseURL.absoluteString,
            kind: kind,
            targetId: targetId,
            path: path,
            bodyData: bodyData,
            createdAt: Date(),
            state: .pending
        )
        if journaling, let journal {
            do {
                try journal.record(entry)
            } catch {
                throw APIError.journal(error.localizedDescription)
            }
        }
        do {
            let request = try makeRequest(
                path: path,
                bodyData: bodyData,
                session: session,
                idempotencyKey: idempotencyKey
            )
            let (data, response) = try await performNoRetry(request)
            try validate(response, data: data)
            // 2xx is definitive success; remove before decoding so a decode failure cannot
            // cause the original mutation to be replayed after it already committed.
            if journaling { try? journal?.acknowledge(entry) }
            return try decode(T.self, from: data)
        } catch {
            if journaling, let api = error as? APIError {
                handleJournalFailure(api, entry)
            }
            throw error
        }
    }

    private func makeRequest(
        path: String,
        bodyData: Data,
        session: IOSSession,
        idempotencyKey: String
    ) throws -> URLRequest {
        var request = URLRequest(
            url: try url(path: path, query: [], baseURL: session.baseURL)
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = bodyData
        return request
    }

    private func handleJournalFailure(_ error: APIError, _ entry: PendingMutation) {
        guard let journal else { return }
        switch error {
        case .http(let status, _, _):
            if status >= 500 { return }
            try? journal.remove(entry)
        case .server(let status, let code, _, _, _):
            if status >= 500 { return }
            if code == "idempotency_conflict" {
                try? journal.markConflict(entry)
            } else {
                try? journal.remove(entry)
            }
        case .unauthorized, .forbidden:
            // No mutation was applied; do not retain personal payloads after auth failure.
            try? journal.remove(entry)
        case .transport, .decoding, .journal,
             .invalidBaseURL, .invalidPairingCode, .invalidLabel:
            return
        }
    }


    private func get<T: Decodable>(
        path: String,
        query: [URLQueryItem],
        session: IOSSession,
        timeout: TimeInterval = 10,
        transport overridingTransport: HTTPTransport? = nil,
        retries: Int? = nil
    ) async throws -> T {
        let activeTransport = overridingTransport ?? transport
        let retryLimit = retries ?? maxGETRetries
        var request = URLRequest(url: try url(path: path, query: query, baseURL: session.baseURL))
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")

        var attempt = 0
        while true {
            do {
                let (data, response) = try await perform(request, using: activeTransport)
                try validate(response, data: data)
                return try decode(T.self, from: data)
            } catch let failure as TransportFailure {
                guard attempt < retryLimit, failure.isTransient else {
                    if failure.code == .timedOut {
                        throw APIError.transport(
                            "The server did not respond within \(Int(timeout)) seconds."
                        )
                    }
                    throw APIError.transport(failure.message)
                }
                attempt += 1
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 300_000_000)
            }
        }
    }

    private func performNoRetry(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.data(for: request)
        } catch let failure as TransportFailure {
            throw APIError.transport(failure.message)
        } catch let error as URLError {
            throw APIError.transport(
                error.code.clientFacingMessage ?? error.localizedDescription
            )
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport("The server could not be reached.")
        }
    }

    private func perform(
        _ request: URLRequest,
        using activeTransport: HTTPTransport
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await activeTransport.data(for: request)
        } catch let error as URLError {
            throw TransportFailure(
                code: error.code,
                message: error.code.clientFacingMessage ?? error.localizedDescription
            )
        } catch {
            throw APIError.transport("The server could not be reached.")
        }
    }

    private func url(path: String, query: [URLQueryItem], baseURL: URL) throws -> URL {
        var url = baseURL
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidBaseURL("That is not a valid server address.")
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let final = components.url else {
            throw APIError.invalidBaseURL("That is not a valid server address.")
        }
        return final
    }

    private func validate(_ response: HTTPURLResponse, data: Data) throws {
        switch response.statusCode {
        case 200...299:
            return
        case 401:
            throw APIError.unauthorized
        case 403:
            throw APIError.forbidden
        default:
            let body = try? JSONDecoder().decode(ServerErrorBody.self, from: data)
            let message = body?.error ?? "The server returned HTTP \(response.statusCode)."
            if let code = body?.code {
                throw APIError.server(
                    status: response.statusCode,
                    code: code,
                    message: message,
                    fields: body?.fields ?? [:],
                    details: body?.details ?? [:]
                )
            }
            throw APIError.http(
                status: response.statusCode,
                message: message,
                fields: body?.fields ?? [:]
            )
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw APIError.decoding
        }
    }
}
