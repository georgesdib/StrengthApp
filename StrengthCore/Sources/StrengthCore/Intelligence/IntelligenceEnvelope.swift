import Foundation

/// The deterministic envelope shared with the server (schema intelligence.envelope.v1).
///
/// Unknown fields are ignored by Codable; a missing required field fails decoding, which is the
/// contract the adapter relies on. The model carries no derived values: every number is the
/// server's and the view only formats it.
public struct IntelligenceEnvelope: Decodable, Equatable {
    public struct Period: Decodable, Equatable {
        public let start: String
        public let end: String
        public let days: Int
        public let weeks: Int?
        public let timezone: String
    }

    public struct FactBlock: Decodable, Equatable {
        public let value: JSONValue
        public let basis: String
        public let method: String
        public let unit: String?
        public let n: Int?
        public let gate: String?
        public let note: String?
    }

    public struct Observation: Decodable, Equatable {
        public let family: String
        public let text: String
        public let gate: String?
        public let n: Int?
        public let evidenceId: String?
        public let limitations: [String]?
    }

    public let schemaVersion: String
    public let capability: String
    public let status: String
    public let asOf: String
    public let period: Period
    public let facts: [String: FactBlock]
    public let observations: [Observation]?
    public let coverage: [String: JSONValue]
    public let missing: [String]
    public let limitations: [String]
    public let qualityFlags: [String]?
    public let generatedAt: String?
}

public extension JSONValue {
    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// Presentation text only; never used to compare or compute a metric.
    var displayText: String {
        switch self {
        case .string(let value): return value
        case .number(let value):
            return value == value.rounded()
                ? String(Int(value))
                : String(format: "%.1f", value)
        case .bool(let value): return value ? "Yes" : "No"
        case .null: return "—"
        case .array, .object: return "—"
        }
    }
}
