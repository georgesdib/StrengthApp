import Foundation
#if canImport(FoundationModels) && os(iOS)
import FoundationModels
#endif

public struct ChatMessage: Identifiable, Equatable, Sendable {
    public enum Role: String, Sendable { case user, assistant }
    public let id: UUID
    public let role: Role
    public let text: String
    public let sources: [String]
    public let suggestions: [String]
    public let unverifiedNumbers: [String]

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        sources: [String] = [],
        suggestions: [String] = [],
        unverifiedNumbers: [String] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.sources = sources
        self.suggestions = suggestions
        self.unverifiedNumbers = unverifiedNumbers
    }
}

public struct ChatReply: Sendable {
    public let text: String
    public let sources: [String]
    public let suggestions: [String]
    public let unverifiedNumbers: [String]
    public init(
        text: String,
        sources: [String],
        suggestions: [String] = [],
        unverifiedNumbers: [String] = []
    ) {
        self.text = text
        self.sources = sources
        self.suggestions = suggestions
        self.unverifiedNumbers = unverifiedNumbers
    }
}

public protocol ChatFactsProviding: IntelligenceCapabilityProviding {
    var recordedEnvelopes: [IntelligenceEnvelope] { get }
    var recordedSources: [String] { get }
    func resetRecord()
}

public enum ChatError: LocalizedError {
    case unavailable(String)
    case tooLong
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .tooLong: return "The answer was too long. Try a narrower question."
        case .failed(let message): return message
        }
    }
}

#if canImport(FoundationModels) && os(iOS)
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
@Generable
public struct ChatAnswer {
    @Guide(description: "The factual answer, grounded in tool results.")
    public var answer: String
    @Guide(description: "Optional suggestions for changes. Empty when none are requested. These are proposals, not facts.")
    public var suggestions: [String]
    public init(answer: String = "", suggestions: [String] = []) {
        self.answer = answer
        self.suggestions = suggestions
    }
}
#endif

@MainActor
public protocol TrainingChatGenerating {
    func availability() -> NarrativeAvailability
    func reply(to question: String, history: [ChatMessage]) async throws -> ChatReply
}

public enum ChatPrompt {
    /// Numbers used as a time window ("last 3 months") are not data claims. They only ground when
    /// the answer also uses them as a time window, so "3 sessions" cannot borrow "3 months".
    public static func timeNumbers(in text: String) -> Set<String> {
        let pattern = "(?<![\\w.])(\\d+(?:[.,]\\d+)?)\\s*(?:days?|weeks?|months?|years?)"
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var numbers: Set<String> = []
        for match in regex.matches(in: text, range: range) {
            guard let numberRange = Range(match.range(at: 1), in: text) else { continue }
            let token = String(text[numberRange])
            numbers.insert(token)
            numbers.insert(token.replacingOccurrences(of: ",", with: ""))
            numbers.insert(token.replacingOccurrences(of: ",", with: "."))
        }
        return numbers
    }

    public static func timeNumbers(question: String, history: [ChatMessage]) -> Set<String> {
        var numbers = timeNumbers(in: question)
        for message in history where message.role == .user {
            numbers.formUnion(timeNumbers(in: message.text))
        }
        return numbers
    }

    public static func allowedNumbers(
        data: Set<String>, questionTime: Set<String>, answer: String
    ) -> Set<String> {
        data.union(questionTime.intersection(timeNumbers(in: answer)))
    }

    public static func build(
        question: String,
        history: [ChatMessage],
        correction: String? = nil,
        maxCharacters: Int = 2_400
    ) -> String {
        var lines: [String] = []
        for message in history.suffix(6) {
            let prefix = message.role == .user ? "Athlete" : "Assistant"
            lines.append("\(prefix): \(String(message.text.prefix(400)))")
        }
        lines.append("Question: \(question)")
        if let correction {
            lines.append("Correction: \(correction)")
        }
        let text = lines.joined(separator: "\n")
        return String(text.suffix(maxCharacters))
    }
}

#if canImport(FoundationModels) && os(iOS)
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
@MainActor
public final class FoundationChatGenerator: TrainingChatGenerating {
    private let facts: any ChatFactsProviding
    private let includePlan: Bool

    public init(facts: any ChatFactsProviding, includePlan: Bool = false) {
        self.facts = facts
        self.includePlan = includePlan
    }

    public func availability() -> NarrativeAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable(NarrativeUnavailableReason.deviceNotEligible.message)
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(NarrativeUnavailableReason.appleIntelligenceNotEnabled.message)
        case .unavailable(.modelNotReady):
            return .unavailable(NarrativeUnavailableReason.modelNotReady.message)
        @unknown default:
            return .unavailable("The on-device model is not available right now.")
        }
    }

    public func reply(to question: String, history: [ChatMessage]) async throws -> ChatReply {
        guard availability().isAvailable else {
            throw ChatError.unavailable(availability().reasonText)
        }
        var correction: String?
        for attempt in 0..<2 {
            let result = try await generate(
                question: question, history: history, correction: correction
            )
            switch result {
            case .grounded(let reply):
                return reply
            case .soft(let reply):
                if attempt == 0 {
                    correction = "Your previous answer used numbers that are not in the facts: "
                        + "\(reply.unverifiedNumbers.joined(separator: ", ")). Rewrite the answer "
                        + "using only numbers from the tool results, or say you cannot verify them."
                    continue
                }
                return reply
            }
        }
        throw ChatError.failed("The answer could not be generated.")
    }

    private enum Attempt {
        case grounded(ChatReply)
        case soft(ChatReply)
    }

    private func generate(
        question: String,
        history: [ChatMessage],
        correction: String?
    ) async throws -> Attempt {
        let prompt = ChatPrompt.build(
            question: question, history: history, correction: correction
        )
        for toolLimit in [5, 3] {
            facts.resetRecord()
            let failureLog = ToolFailureLog()
            let tools = Array(
                IntelligenceTools.make(
                    provider: facts, failureLog: failureLog, includePlan: includePlan
                ).prefix(toolLimit)
            )
            let session = LanguageModelSession(
                model: SystemLanguageModel.default,
                tools: tools,
                instructions: instructions
            )
            do {
                let response = try await session.respond(to: prompt, generating: ChatAnswer.self)
                let content = response.content
                let text = content.answer
                let suggestions = Array(content.suggestions.prefix(3)).map {
                    String($0.prefix(240))
                }
                let envelopes = facts.recordedEnvelopes
                let failures = failureLog.failures
                if envelopes.isEmpty, failures.contains(.unauthorized) {
                    throw ChatError.unavailable(
                        "Your training data could not be accessed. Check the pairing."
                    )
                }
                if envelopes.isEmpty,
                   failures.contains(where: { $0 == .unavailable || $0 == .server }) {
                    throw ChatError.failed("Your training data is temporarily unavailable. Try again.")
                }
                guard text.count <= 2_500 else { throw ChatError.tooLong }
                let questionTime = ChatPrompt.timeNumbers(question: question, history: history)
                let allowed = ChatPrompt.allowedNumbers(
                    data: NarrativeContext.allowedNumbers(in: envelopes),
                    questionTime: questionTime,
                    answer: text
                )
                let ungrounded = NarrativeValidator.numbers(in: text).filter {
                    !NarrativeValidator.isGrounded($0, allowedNumbers: allowed)
                }
                let reply = ChatReply(
                    text: text,
                    sources: facts.recordedSources,
                    unverifiedNumbers: ungrounded
                )
                return ungrounded.isEmpty ? .grounded(reply) : .soft(reply)
            } catch let error as ChatError {
                throw error
            } catch {
                if isContextOverflow(error), toolLimit == 5 { continue }
                throw mapped(error)
            }
        }
        throw ChatError.failed("The conversation was too large for the on-device model.")
    }

    private var instructions: String {
        "You are a training assistant on the athlete's iPhone. Answer only from the facts the tools "
        + "return; call a tool before making a data claim. Never invent a number in the factual "
        + "answer. You may suggest changes and discuss medical considerations, but put them in the "
        + "suggestions field, never in the answer: they are proposals, not facts, and they are never "
        + "applied. If the tools cannot answer, say so plainly. If a tool says it could not find "
        + "something, ask the athlete to clarify; never repeat a raw tool error. Keep the answer under "
        + "150 words."
    }

    private func isContextOverflow(_ error: Error) -> Bool {
        if let generation = error as? LanguageModelSession.GenerationError,
           case .exceededContextWindowSize = generation {
            return true
        }
        let text = error.localizedDescription.lowercased()
        return text.contains("token") && (text.contains("maximum") || text.contains("context"))
    }

    private func mapped(_ error: Error) -> ChatError {
        if isContextOverflow(error) {
            return .failed("The conversation was too large for the on-device model.")
        }
        if let generation = error as? LanguageModelSession.GenerationError,
           case .unsupportedLanguageOrLocale = generation {
            return .unavailable("The on-device model does not support this language yet.")
        }
        return .failed(error.localizedDescription)
    }
}

#endif
