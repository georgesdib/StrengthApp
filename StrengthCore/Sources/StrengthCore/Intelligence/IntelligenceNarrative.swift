import Foundation
#if canImport(FoundationModels) && os(iOS)
import FoundationModels
#endif

/// How much room the on-device explanation may use. Presentation limits, not model limits.
public enum NarrativeDetail: String, CaseIterable, Codable, Sendable {
    case concise
    case standard
    case detailed

    public var title: String {
        switch self {
        case .concise: return "Concise"
        case .standard: return "Standard"
        case .detailed: return "Detailed"
        }
    }

    public var headlineLimit: Int {
        switch self {
        case .concise, .standard: return 120
        case .detailed: return 160
        }
    }

    public var observationLimit: Int {
        switch self {
        case .concise: return 200
        case .standard: return 240
        case .detailed: return 320
        }
    }

    public var observationCount: Int {
        switch self {
        case .concise: return 2
        case .standard: return 3
        case .detailed: return 4
        }
    }

    public var limitationLimit: Int {
        switch self {
        case .concise, .standard: return 160
        case .detailed: return 200
        }
    }
}

public enum NarrativeKind: String, Sendable {
    case weeklyReview
    case overview
}

public enum NarrativeAvailability: Equatable, Sendable {
    case available
    case unavailable(String)

    public var isAvailable: Bool { self == .available }
}

#if canImport(FoundationModels) && os(iOS)
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
@Generable
public struct GeneratedNarrative {
    @Guide(description: "One short headline, no numbers that are not in the facts.")
    public var headline: String

    @Guide(description: "Two to four short observations. Each must cite a fact value.")
    public var observations: [String]

    @Guide(description: "One limitation of this explanation, in the athlete's language.")
    public var limitation: String

    public init(headline: String, observations: [String], limitation: String) {
        self.headline = headline
        self.observations = observations
        self.limitation = limitation
    }
}
#else
public struct GeneratedNarrative: Sendable {
    public var headline: String
    public var observations: [String]
    public var limitation: String

    public init(headline: String, observations: [String], limitation: String) {
        self.headline = headline
        self.observations = observations
        self.limitation = limitation
    }
}
#endif

public struct NarrativeContext: Sendable {
    public let kind: NarrativeKind
    public let facts: String
    public let detail: NarrativeDetail

    public init(kind: NarrativeKind, facts: String, detail: NarrativeDetail) {
        self.kind = kind
        self.facts = facts
        self.detail = detail
    }
}

public protocol NarrativeGenerating: Sendable {
    func availability() -> NarrativeAvailability
    func generate(_ context: NarrativeContext) async throws -> GeneratedNarrative
}

public enum NarrativeError: LocalizedError {
    case unavailable(String)
    case notGrounded
    case tooLong
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .notGrounded: return "The explanation mentioned a number that is not in the facts."
        case .tooLong: return "The explanation was longer than the selected detail allows."
        case .failed(let message): return message
        }
    }
}

public enum NarrativeValidator {
    public static func validate(
        _ narrative: GeneratedNarrative, context: NarrativeContext
    ) throws {
        guard narrative.headline.count <= context.detail.headlineLimit,
              narrative.limitation.count <= context.detail.limitationLimit,
              narrative.observations.count <= context.detail.observationCount,
              narrative.observations.allSatisfy({
                  $0.count <= context.detail.observationLimit
              }) else {
            throw NarrativeError.tooLong
        }
        guard numbers(in: narrative).allSatisfy({ grounded($0, in: context.facts) }) else {
            throw NarrativeError.notGrounded
        }
    }

    private static let numberWords: [String: String] = [
        "two": "2", "three": "3", "four": "4", "five": "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
    ]

    private static func numbers(in narrative: GeneratedNarrative) -> [String] {
        let text = ([narrative.headline, narrative.limitation] + narrative.observations)
            .joined(separator: " ")
        let pattern = "\\d+(?:[.,]\\d+)?|\\b(?:two|three|four|five|six|seven|eight|nine|ten)\\b"
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private static func grounded(_ number: String, in facts: String) -> Bool {
        if facts.contains(number) { return true }
        if let digit = numberWords[number.lowercased()] { return facts.contains(digit) }
        return false
    }
}

public extension NarrativeContext {
    /// Compact, human-readable facts. No evidence arrays or provenance internals.
    static func weeklyReview(_ envelope: IntelligenceEnvelope, detail: NarrativeDetail) -> NarrativeContext {
        NarrativeContext(kind: .weeklyReview, facts: projection(envelope), detail: detail)
    }

    static func overview(_ envelope: IntelligenceEnvelope, detail: NarrativeDetail) -> NarrativeContext {
        NarrativeContext(kind: .overview, facts: projection(envelope), detail: detail)
    }

    private static func projection(_ envelope: IntelligenceEnvelope) -> String {
        var lines: [String] = []
        lines.append("capability: \(envelope.capability)")
        lines.append("status: \(envelope.status)")
        lines.append("period: \(envelope.period.start) to \(envelope.period.end)")
        for key in envelope.facts.keys.sorted() {
            guard let fact = envelope.facts[key] else { continue }
            lines.append("\(key): \(flatten(fact.value))"
                         + (fact.unit.map { " \($0)" } ?? "")
                         + (fact.gate.map { " (gate: \($0))" } ?? ""))
        }
        if let observations = envelope.observations {
            for observation in observations {
                lines.append("observation: \(observation.text) (n=\(observation.n ?? 0))")
            }
        }
        for item in envelope.missing { lines.append("missing: \(item)") }
        for item in envelope.limitations { lines.append("limitation: \(item)") }
        let text = lines.joined(separator: "\n")
        return String(text.prefix(6_000))
    }

    private static func flatten(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): return text
        case .number(let number):
            return number == number.rounded()
                ? String(Int(number))
                : String(format: "%.1f", number)
        case .bool(let flag): return flag ? "yes" : "no"
        case .null: return "unknown"
        case .array(let items): return items.map(flatten).joined(separator: ", ")
        case .object(let object):
            return object.keys.sorted().map { "\($0)=\(flatten(object[$0] ?? .null))" }
                .joined(separator: ", ")
        }
    }
}

#if canImport(FoundationModels) && os(iOS)
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct FoundationNarrativeGenerator: NarrativeGenerating {
    public init() {}

    public func availability() -> NarrativeAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable("This iPhone does not support Apple Intelligence.")
            case .appleIntelligenceNotEnabled:
                return .unavailable("Turn on Apple Intelligence in Settings to use explanations.")
            case .modelNotReady:
                return .unavailable("The on-device model is still downloading. Try again later.")
            @unknown default:
                return .unavailable("The on-device model is not available right now.")
            }
        }
    }

    public func generate(_ context: NarrativeContext) async throws -> GeneratedNarrative {
        guard availability().isAvailable else {
            throw NarrativeError.unavailable(availability().reasonText)
        }
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: instructions(for: context)
        )
        do {
            let response = try await session.respond(
                to: prompt(for: context),
                generating: GeneratedNarrative.self
            )
            let narrative = response.content
            try NarrativeValidator.validate(narrative, context: context)
            return narrative
        } catch let error as LanguageModelSession.GenerationError {
            throw NarrativeError.failed(message(for: error))
        }
    }

    private func instructions(for context: NarrativeContext) -> String {
        "You explain training data to the athlete who recorded it. Use only the facts provided. "
        + "Never invent a number, never prescribe a load or a plan, and never give medical advice. "
        + "Write plainly and briefly. Return at most \(context.detail.observationCount) observations."
    }

    private func prompt(for context: NarrativeContext) -> String {
        let question = context.kind == .weeklyReview
            ? "What happened this week, what changed, and what should I discuss with the engine?"
            : "Where are the last four weeks going, and what should I discuss with the engine?"
        return "Question: \(question)\n\nFacts:\n\(context.facts)"
    }

    private func message(for error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize:
            return "The facts were too large for the on-device model. The review is shown without an explanation."
        case .unsupportedLanguageOrLocale:
            return "The on-device model does not support this language yet."
        case .guardrailViolation, .refusal:
            return "The on-device model declined to answer."
        case .assetsUnavailable:
            return "The on-device model is not ready yet."
        case .concurrentRequests, .rateLimited:
            return "The on-device model is busy. Try again in a moment."
        default:
            return "The explanation could not be generated."
        }
    }
}

private extension NarrativeAvailability {
    var reasonText: String {
        if case .unavailable(let reason) = self { return reason }
        return "The on-device model is not available."
    }
}
#endif
