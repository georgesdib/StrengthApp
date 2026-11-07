import Foundation

/// One paired server session: the base URL the owner entered and the Keychain-held token.
struct IOSSession: Equatable {
    let baseURL: URL
    let token: String
}

enum APIError: LocalizedError, Equatable {
    case invalidBaseURL(String)
    case invalidPairingCode
    case invalidLabel(String)
    case transport(String)
    case http(status: Int, message: String, fields: [String: String])
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
            if (500...599).contains(status) {
                return "The server could not complete the request (HTTP \(status))."
            }
            if let field = fields.sorted(by: { $0.key < $1.key }).first {
                return "\(message) (\(field.key): \(field.value))"
            }
            return message
        case .unauthorized, .forbidden:
            return "This device is no longer paired. Pair it again."
        case .decoding:
            return "The server response could not be read."
        }
    }

    var isAuthenticationFailure: Bool {
        switch self {
        case .unauthorized, .forbidden: return true
        default: return false
        }
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
enum RedirectPolicy {
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
    private let maxGETRetries = 2

    init(transport: HTTPTransport = URLSessionTransport()) {
        self.transport = transport
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
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

    // MARK: Requests

    private struct PairRequest: Encodable {
        let code: String
        let label: String
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
            throw APIError.http(
                status: response.statusCode,
                message: body?.error ?? "The server returned HTTP \(response.statusCode).",
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
