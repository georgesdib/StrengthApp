import Foundation

// MARK: - OpenAI-compatible wire types (DeepSeek)

public struct DeepSeekToolCall: Codable, Sendable, Equatable {
    public struct Function: Codable, Sendable, Equatable {
        public let name: String
        public let arguments: String
        public init(name: String, arguments: String) {
            self.name = name
            self.arguments = arguments
        }
    }
    public let id: String
    public let type: String
    public let function: Function
    public init(id: String, type: String = "function", function: Function) {
        self.id = id
        self.type = type
        self.function = function
    }
}

public struct DeepSeekMessage: Codable, Sendable {
    public let role: String
    public let content: String?
    public let toolCalls: [DeepSeekToolCall]?
    public let toolCallID: String?

    public init(
        role: String,
        content: String? = nil,
        toolCalls: [DeepSeekToolCall]? = nil,
        toolCallID: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }
}

public struct DeepSeekTool: Encodable, Sendable {
    public struct Function: Encodable, Sendable {
        public let name: String
        public let description: String
        public let parameters: JSONValue
        public init(name: String, description: String, parameters: JSONValue) {
            self.name = name
            self.description = description
            self.parameters = parameters
        }
    }
    public let type: String
    public let function: Function
    public init(function: Function) {
        self.type = "function"
        self.function = function
    }
}

public struct DeepSeekChatResult: Sendable {
    public let content: String?
    public let toolCalls: [DeepSeekToolCall]
    public init(content: String?, toolCalls: [DeepSeekToolCall]) {
        self.content = content
        self.toolCalls = toolCalls
    }
}

public protocol DeepSeekCompleting: Sendable {
    func complete(messages: [DeepSeekMessage], tools: [DeepSeekTool]) async throws -> DeepSeekChatResult
    func validateKey() async throws
}

public enum DeepSeekError: LocalizedError, Equatable {
    case missingKey
    case invalidKey
    case rateLimited
    case unavailable(String)
    case badResponse
    case server(Int)

    public var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Add a DeepSeek API key in Settings to use this model."
        case .invalidKey:
            return "The DeepSeek API key is not valid."
        case .rateLimited:
            return "DeepSeek rate limit reached. Try again later."
        case .unavailable(let message):
            return message
        case .badResponse:
            return "DeepSeek returned an unexpected response."
        case .server(let status):
            return "DeepSeek is temporarily unavailable (HTTP \(status))."
        }
    }
}

public final class DeepSeekClient: DeepSeekCompleting, @unchecked Sendable {
    private let apiKey: String?
    private let baseURL: URL
    private let session: URLSession

    public init(
        apiKey: String?,
        baseURL: URL = URL(string: "https://api.deepseek.com/")!,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = baseURL
        self.session = session
    }

    public func validateKey() async throws {
        var request = try makeRequest(path: "models", method: "GET")
        request.timeoutInterval = 20
        _ = try await send(request)
    }

    public func complete(
        messages: [DeepSeekMessage],
        tools: [DeepSeekTool]
    ) async throws -> DeepSeekChatResult {
        var request = try makeRequest(path: "chat/completions", method: "POST")
        request.timeoutInterval = 60
        let body = Request(
            model: "deepseek-chat",
            messages: messages,
            tools: tools,
            toolChoice: "auto",
            temperature: 0.2,
            maxTokens: 1_200,
            stream: false
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(body)

        let data = try await send(request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let response = try? decoder.decode(Response.self, from: data),
              let choice = response.choices.first else {
            throw DeepSeekError.badResponse
        }
        let message = choice.message
        return DeepSeekChatResult(
            content: message.content?.isEmpty == false ? message.content : nil,
            toolCalls: message.toolCalls ?? []
        )
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard let apiKey, !apiKey.isEmpty else { throw DeepSeekError.missingKey }
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw DeepSeekError.badResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DeepSeekError.unavailable(
                "Could not reach DeepSeek. Check the network and try again."
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw DeepSeekError.badResponse
        }
        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw DeepSeekError.invalidKey
        case 429:
            throw DeepSeekError.rateLimited
        case 500...:
            throw DeepSeekError.server(http.statusCode)
        default:
            throw DeepSeekError.badResponse
        }
    }

    private struct Request: Encodable {
        let model: String
        let messages: [DeepSeekMessage]
        let tools: [DeepSeekTool]
        let toolChoice: String
        let temperature: Double
        let maxTokens: Int
        let stream: Bool
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            let message: Message
        }
        struct Message: Decodable {
            let content: String?
            let toolCalls: [DeepSeekToolCall]?
        }
        let choices: [Choice]
    }
}
