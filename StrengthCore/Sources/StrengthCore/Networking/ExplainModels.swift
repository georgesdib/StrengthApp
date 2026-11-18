import Foundation

/// A project citation returned by the server's local knowledge index.
public struct ExplainCitation: Codable, Identifiable, Equatable, Sendable {
    public var id: String { path + ":" + String(lineStart) + "-" + String(lineEnd) }

    public let path: String
    public let lineStart: Int
    public let lineEnd: Int
    public let source: String
    public let url: String?
    public let verified: Bool
    public let warning: String?

    public var label: String {
        source + ":" + path + ":" + String(lineStart) + (lineEnd == lineStart ? "" : "-" + String(lineEnd))
    }
}

public struct ExplainResponse: Codable, Equatable, Sendable {
    public let answer: String
    public let citations: [ExplainCitation]
    public let warnings: [String]
    public let grounded: Bool
    public let sources: [String]
    public let tokens: Int?
    public let model: String?
    public let indexCommit: String?
}
