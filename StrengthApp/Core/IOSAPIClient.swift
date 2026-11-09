import Foundation

/// One paired server session: the base URL the owner entered and the Keychain-held token.
struct IOSSession: Equatable {
    let baseURL: URL
    let token: String
    let deviceID: String?

    init(baseURL: URL, token: String, deviceID: String? = nil) {
        self.baseURL = baseURL
        self.token = token
        self.deviceID = deviceID
    }
}

enum APIError: LocalizedError, Equatable {
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

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let message):
            return message
        case .invalidPairingCode:
            return "Enter the 8-digit code printed by strength-coach ios pair."
        case .invalidLabel(let message):
            return message
        case .transport:
            return "Could not reach the server. Check that it is running and that this iPhone is on the same network."
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

    static func httpDescription(status: Int, message: String,
                                fields: [String: String]) -> String {
        if (500...599).contains(status) {
            return "The server could not complete the request (HTTP \(status))."
        }
        if let field = fields.sorted(by: { $0.key < $1.key }).first {
            return "\(message) (\(field.key): \(field.value))"
        }
        return message
    }

    var isAuthenticationFailure: Bool {
        switch self {
        case .unauthorized, .forbidden: return true
        default: return false
        }
    }

    var code: String? {
        if case .server(_, let code, _, _, _) = self { return code }
        return nil
    }

    var details: [String: JSONValue]? {
        if case .server(_, _, _, _, let details) = self { return details }
        return nil
    }
}

// MARK: - Transport

protocol HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// A GET-only transport with no cookies or shared cache. Redirects are allowed only within the
/// original origin (scheme, host and port) so the bearer token can never follow a redirect to
/// another server, port or HTTP/HTTPS scheme.
final class URLSessionTransport: HTTPTransport {
    private let session: URLSession

    init(timeout: TimeInterval = 10) {
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

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
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
nonisolated enum RedirectPolicy {
    struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int
    }

    static func origin(of url: URL?) -> Origin? {
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

    static func allowsRedirect(from original: URL?, to target: URL?) -> Bool {
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
final class SameHostRedirectGuard: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(
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
final class IOSAPIClient {
    private let transport: HTTPTransport
    private let decoder: JSONDecoder
    private let encoder = JSONEncoder()
    private let journal: MutationJournal?
    private let maxGETRetries = 2

    init(
        transport: HTTPTransport = URLSessionTransport(),
        journal: MutationJournal? = nil
    ) {
        self.transport = transport
        self.journal = journal
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    // MARK: Input validation

    static func validatedBaseURL(_ raw: String) throws -> URL {
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

    static func normalizeCode(_ raw: String) throws -> String {
        let cleaned = raw
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard cleaned.count == 8,
              cleaned.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw APIError.invalidPairingCode
        }
        return cleaned
    }

    static func normalizeLabel(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmed.isEmpty ? "iPhone" : trimmed
        guard label.count <= 40 else {
            throw APIError.invalidLabel("The device label must be 1-40 characters.")
        }
        return label
    }

    // MARK: Endpoints

    func pair(baseURL: URL, code: String, label: String) async throws -> PairResponse {
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

    func bootstrap(session: IOSSession) async throws -> BootstrapResponse {
        try await get(path: "api/ios/v1/bootstrap", query: [], session: session)
    }

    /// Short, read-only reachability check used for Home/Away selection. A 401 still proves
    /// the server is reachable; transport errors and 5xx do not.
    func isServerReachable(baseURL: URL, token: String) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/ios/v1/bootstrap"))
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await transport.data(for: request)
            return (200...499).contains(response.statusCode)
        } catch {
            return false
        }
    }

    func today(session: IOSSession) async throws -> TodayResponse {
        try await get(path: "api/ios/v1/today", query: [], session: session)
    }

    func history(session: IOSSession, limit: Int = 50, offset: Int = 0) async throws -> HistoryResponse {
        try await get(
            path: "api/ios/v1/history",
            query: [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset)),
            ],
            session: session
        )
    }

    func historyDetail(sessionID: String, session: IOSSession) async throws -> HistoryDetail {
        try await get(
            path: "api/ios/v1/history/\(sessionID)",
            query: [],
            session: session
        )
    }

    func writeReadiness(
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

    func importHealthKitReadiness(
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

    /// R7: the request is accepted (202) and the plan is built in the background.
    func issuePrescription(
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

    /// The authoritative plan-request state. Read-only: no idempotency key, no retries beyond
    /// the bounded GET policy.
    func planState(session: IOSSession) async throws -> PlansStateResponse {
        try await get(path: "api/ios/v1/plans/current", query: [], session: session)
    }

    func startWorkout(
        issuedPlanId: String,
        session: IOSSession,
        idempotencyKey: String
    ) async throws -> WorkoutDetail {
        try await post(
            path: "api/ios/v1/workouts",
            body: StartWorkoutRequest(issuedPlanId: issuedPlanId),
            kind: .startWorkout,
            targetId: issuedPlanId,
            session: session,
            idempotencyKey: idempotencyKey
        )
    }

    func addSet(
        workoutId: String,
        body: AddSetRequest,
        session: IOSSession,
        idempotencyKey: String,
        journaling: Bool = true
    ) async throws -> WorkoutDetail {
        try await post(
            path: "api/ios/v1/workouts/\(workoutId)/sets",
            body: body,
            kind: .addSet,
            targetId: workoutId,
            session: session,
            idempotencyKey: idempotencyKey,
            journaling: journaling
        )
    }

    func removeSet(
        workoutId: String,
        body: RemoveSetRequest,
        session: IOSSession,
        idempotencyKey: String
    ) async throws -> WorkoutDetail {
        try await post(
            path: "api/ios/v1/workouts/\(workoutId)/remove-set",
            body: body,
            kind: .removeSet,
            targetId: workoutId,
            session: session,
            idempotencyKey: idempotencyKey
        )
    }

    func discardPendingOperation(_ operationId: String) {
        try? journal?.remove(operationId: operationId)
    }

    func exerciseCatalogue(session: IOSSession) async throws -> ExerciseCatalogueResponse {
        try await get(path: "api/ios/v1/exercises", query: [], session: session)
    }

    func exerciseDetail(
        exerciseId: String,
        session: IOSSession
    ) async throws -> ExerciseDetailResponse {
        try await get(
            path: "api/ios/v1/exercises/\(exerciseId)",
            query: [],
            session: session
        )
    }

    func exerciseHistory(
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

    func swapPlanExercise(
        workoutId: String,
        itemIndex: Int,
        body: PlanSwapRequest,
        session: IOSSession,
        idempotencyKey: String
    ) async throws -> WorkoutDetail {
        try await post(
            path: "api/ios/v1/workouts/\(workoutId)/plan/items/\(itemIndex)/swap",
            body: body,
            kind: .planEdit,
            targetId: workoutId,
            session: session,
            idempotencyKey: idempotencyKey
        )
    }

    func removePlanExercise(
        workoutId: String,
        itemIndex: Int,
        body: PlanRemoveRequest,
        session: IOSSession,
        idempotencyKey: String
    ) async throws -> WorkoutDetail {
        try await post(
            path: "api/ios/v1/workouts/\(workoutId)/plan/items/\(itemIndex)/remove",
            body: body,
            kind: .planEdit,
            targetId: workoutId,
            session: session,
            idempotencyKey: idempotencyKey
        )
    }

    func changePlanSets(
        workoutId: String,
        itemIndex: Int,
        body: PlanSetsRequest,
        session: IOSSession,
        idempotencyKey: String
    ) async throws -> WorkoutDetail {
        try await post(
            path: "api/ios/v1/workouts/\(workoutId)/plan/items/\(itemIndex)/sets",
            body: body,
            kind: .planEdit,
            targetId: workoutId,
            session: session,
            idempotencyKey: idempotencyKey
        )
    }

    func addPlanExercise(
        workoutId: String,
        body: PlanAddRequest,
        session: IOSSession,
        idempotencyKey: String
    ) async throws -> WorkoutDetail {
        try await post(
            path: "api/ios/v1/workouts/\(workoutId)/plan/exercises",
            body: body,
            kind: .planEdit,
            targetId: workoutId,
            session: session,
            idempotencyKey: idempotencyKey
        )
    }

    func rateForm(
        workoutId: String,
        body: FormRatingRequest,
        session: IOSSession,
        idempotencyKey: String,
        journaling: Bool = true
    ) async throws -> WorkoutDetail {
        try await post(
            path: "api/ios/v1/workouts/\(workoutId)/form",
            body: body,
            kind: .rateForm,
            targetId: workoutId,
            session: session,
            idempotencyKey: idempotencyKey,
            journaling: journaling
        )
    }

    func completeWorkout(
        workoutId: String,
        body: CompleteWorkoutRequest,
        session: IOSSession,
        idempotencyKey: String,
        journaling: Bool = true
    ) async throws -> WorkoutDetail {
        try await post(
            path: "api/ios/v1/workouts/\(workoutId)/complete",
            body: body,
            kind: .completeWorkout,
            targetId: workoutId,
            session: session,
            idempotencyKey: idempotencyKey,
            journaling: journaling
        )
    }

    func abandonWorkout(
        workoutId: String,
        session: IOSSession,
        idempotencyKey: String
    ) async throws -> WorkoutDetail {
        try await post(
            path: "api/ios/v1/workouts/\(workoutId)/abandon",
            body: EmptyRequest(),
            kind: .abandonWorkout,
            targetId: workoutId,
            session: session,
            idempotencyKey: idempotencyKey
        )
    }

    func progress(
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

    // MARK: Pending operations

    func pendingMutations(for session: IOSSession) -> [PendingMutation] {
        journal?.all(
            for: session.deviceID,
            serverURL: session.baseURL.absoluteString
        ) ?? []
    }

    func discard(_ entry: PendingMutation) {
        try? journal?.remove(entry)
    }

    func discardAll(for session: IOSSession) {
        try? journal?.removeAll(
            for: session.deviceID,
            serverURL: session.baseURL.absoluteString
        )
    }

    func markConflict(_ entry: PendingMutation) {
        try? journal?.markConflict(entry)
    }

    /// Replay a journaled request with its original UUID and exact encoded body.
    func replay<T: Decodable>(
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
        session: IOSSession
    ) async throws -> T {
        var request = URLRequest(url: try url(path: path, query: query, baseURL: session.baseURL))
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")

        var attempt = 0
        while true {
            do {
                let (data, response) = try await perform(request)
                try validate(response, data: data)
                return try decode(T.self, from: data)
            } catch let failure as TransportFailure {
                guard attempt < maxGETRetries, failure.isTransient else {
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
            throw APIError.transport(error.localizedDescription)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport("The server could not be reached.")
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.data(for: request)
        } catch let error as URLError {
            throw TransportFailure(code: error.code, message: error.localizedDescription)
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
