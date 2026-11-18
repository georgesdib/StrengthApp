import Foundation
#if canImport(FoundationModels) && os(iOS)
import FoundationModels
#endif

public struct ChatToolOutput: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let source: String
    public let text: String
    public init(source: String, text: String) {
        self.source = source
        self.text = text
    }
}

public struct ChatMessage: Identifiable, Equatable, Sendable {
    public enum Role: String, Sendable { case user, assistant }
    public let id: UUID
    public let role: Role
    public let text: String
    public let sources: [String]
    public let suggestions: [String]
    public let unverifiedNumbers: [String]
    public let rawOutputs: [ChatToolOutput]
    public let planCard: PrescriptionCard?

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        sources: [String] = [],
        suggestions: [String] = [],
        unverifiedNumbers: [String] = [],
        rawOutputs: [ChatToolOutput] = [],
        planCard: PrescriptionCard? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.sources = sources
        self.suggestions = suggestions
        self.unverifiedNumbers = unverifiedNumbers
        self.rawOutputs = rawOutputs
        self.planCard = planCard
    }
}

public struct ChatReply: Sendable {
    public let text: String
    public let sources: [String]
    public let suggestions: [String]
    public let unverifiedNumbers: [String]
    public let rawOutputs: [ChatToolOutput]
    public let planCard: PrescriptionCard?
    public init(
        text: String,
        sources: [String],
        suggestions: [String] = [],
        unverifiedNumbers: [String] = [],
        rawOutputs: [ChatToolOutput] = [],
        planCard: PrescriptionCard? = nil
    ) {
        self.text = text
        self.sources = sources
        self.suggestions = suggestions
        self.unverifiedNumbers = unverifiedNumbers
        self.rawOutputs = rawOutputs
        self.planCard = planCard
    }
}

public protocol ChatFactsProviding: IntelligenceCapabilityProviding {
    var recordedEnvelopes: [IntelligenceEnvelope] { get }
    var recordedSources: [String] { get }
    var recordedOutputs: [ChatToolOutput] { get }
    func resetRecord()
}

public extension ChatFactsProviding {
    var recordedOutputs: [ChatToolOutput] { [] }
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

public enum ChatIntent {
    public static func planToolNames(_ question: String) -> [String] {
        let text = question.lowercased()
        var names: Set<String> = []
        let prescriptionPhrases = [
            "prescription", "prescribed", "training today", "train today",
            "exercises scheduled", "exercises are scheduled", "scheduled exercises", "what should i be doing",
            "what should i do today", "what should i train", "what am i training",
            "what am i doing today", "today's lifts", "today's workout", "today's session",
            "session today", "workout today", "lifts today", "scheduled today",
        ]
        if prescriptionPhrases.contains(where: { text.contains($0) }) {
            names.insert("prescription")
        }
        if text.contains("programme") || text.contains("program ") || text.contains("block") {
            names.insert("programme_summary")
        }
        if text.contains("adherence") || text.contains("compliance")
            || text.contains("missed session") {
            names.insert("adherence")
        }
        if text.contains(" plan") || text.contains("plan ") {
            names.insert("prescription")
            names.insert("programme_summary")
        }
        return names.sorted()
    }

    public static func requiresPlan(_ question: String) -> Bool {
        !planToolNames(question).isEmpty
    }

    public static func planQuery(_ question: String) -> String {
        let text = question.lowercased()
        if let range = text.range(of: "\\d{4}-\\d{2}-\\d{2}", options: .regularExpression) {
            return String(text[range])
        }
        if text.contains("yesterday") { return "yesterday" }
        if text.contains("today") { return "today" }
        if let range = text.range(of: "\\d+\\s*weeks?", options: .regularExpression) {
            return String(text[range]).filter(\.isNumber)
        }
        return ""
    }
}

public enum ChatPlanFactsStatus: String, Sendable {
    case success
    case partial
    case failure
}

public struct ChatPlanFactsResult: Sendable {
    public let status: ChatPlanFactsStatus
    public let context: String?
    public let missing: [String]
    public let failures: [String: CapabilityFailure]

    public init(
        status: ChatPlanFactsStatus,
        context: String?,
        missing: [String],
        failures: [String: CapabilityFailure]
    ) {
        self.status = status
        self.context = context
        self.missing = missing
        self.failures = failures
    }
}

public enum ChatPlanFailure {
    public static func error(for result: ChatPlanFactsResult) -> ChatError {
        let failures = Array(result.failures.values)
        if failures.contains(.unauthorized) {
            return .unavailable("Your training data could not be accessed. Check the pairing.")
        }
        if failures.contains(where: { $0 == .unavailable || $0 == .server }) {
            return .failed("Your training data is temporarily unavailable. Try again.")
        }
        if !failures.isEmpty, failures.allSatisfy({ $0 == .notFound }) {
            return .failed("No plan data was found for that request.")
        }
        if failures.contains(.invalidIdentifier) {
            return .failed("That plan request was not valid.")
        }
        return .failed("Plan data could not be loaded.")
    }
}

public enum ChatPlanFacts {
    public static func load(
        question: String,
        names: [String],
        facts: any ChatFactsProviding
    ) async -> ChatPlanFactsResult {
        guard let plan = facts as? any PlanFactsProviding else {
            return ChatPlanFactsResult(
                status: .failure, context: nil, missing: names,
                failures: Dictionary(uniqueKeysWithValues: names.map { ($0, .unknown) })
            )
        }
        facts.resetRecord()
        let query = ChatIntent.planQuery(question)
        var blocks: [String] = []
        var missing: [String] = []
        var failures: [String: CapabilityFailure] = [:]

        for name in names {
            do {
                switch name {
                case "prescription":
                    blocks.append("[prescription]\n" + (try await plan.prescription(query: query)))
                case "programme_summary":
                    blocks.append("[programme]\n" + (try await plan.programmeSummary(query: query)))
                case "adherence":
                    blocks.append("[adherence]\n" + (try await plan.adherence(query: query)))
                default:
                    continue
                }
            } catch {
                missing.append(name)
                failures[name] = CapabilityFailure(error)
            }
        }

        if blocks.isEmpty {
            return ChatPlanFactsResult(
                status: .failure, context: nil, missing: names, failures: failures
            )
        }
        var context = blocks.joined(separator: "\n\n")
        if !missing.isEmpty {
            context += "\n\nUnavailable plan sections (do not make claims about them): "
                + missing.joined(separator: ", ")
        }
        return ChatPlanFactsResult(
            status: missing.isEmpty ? .success : .partial,
            context: context,
            missing: missing,
            failures: failures
        )
    }
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

    public static func today(now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }

    public static func build(
        question: String,
        history: [ChatMessage],
        correction: String? = nil,
        maxCharacters: Int = 2_400
    ) -> String {
        var lines: [String] = ["Today: \(today())"]
        for message in history.suffix(6) {
            let prefix = message.role == .user ? "Athlete" : "Assistant"
            lines.append("\(prefix): \(String(message.text.prefix(400)))")
        }
        lines.append("Question: \(question)")
        if ChatRefusalFallback.asksAboutLongevity(question) {
            lines.append(
                "Note: this asks for recorded aerobic/longevity data, not medical advice. "
                    + "Report the recorded facts."
            )
        }
        if let correction {
            lines.append("Correction: \(correction)")
        }
        var text = lines.joined(separator: "\n")
        while text.count > maxCharacters, lines.count > 2 {
            lines.remove(at: 1)
            text = lines.joined(separator: "\n")
        }
        return text
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
        let planNames = includePlan ? ChatIntent.planToolNames(question) : []
        let usePlan = !planNames.isEmpty
        let planResult = usePlan
            ? await ChatPlanFacts.load(question: question, names: planNames, facts: facts)
            : nil
        if let planResult, planResult.status == .failure {
            throw ChatPlanFailure.error(for: planResult)
        }
        let planFacts = planResult?.context
        let injectPlan = planFacts != nil
        let promptHistory = usePlan ? Array(history.suffix(2)) : history
        let attempts: [[ChatMessage]] = [promptHistory, []]

        for (index, historyForPrompt) in attempts.enumerated() {
            let base = ChatPrompt.build(
                question: question,
                history: historyForPrompt,
                correction: correction,
                maxCharacters: usePlan ? 1_200 : 2_400
            )
            let prompt = injectPlan
                ? base + "\n\nPlan facts:\n" + (planFacts ?? "")
                : base
            if !injectPlan { facts.resetRecord() }
            let failureLog = ToolFailureLog()
            let tools = injectPlan ? [] as [any Tool] : IntelligenceTools.make(
                provider: facts,
                failureLog: failureLog,
                includePlan: usePlan,
                includeBase: !usePlan,
                planNames: Set(planNames)
            )
            let session = LanguageModelSession(
                model: SystemLanguageModel.default,
                tools: tools,
                instructions: instructions
            )
            do {
                var options = usePlan && !injectPlan
                    ? GenerationOptions(toolCallingMode: .required)
                    : GenerationOptions()
                options.maximumResponseTokens = usePlan ? 900 : 600
                let response = try await session.respond(
                    to: prompt, generating: ChatAnswer.self, options: options
                )
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
                    suggestions: suggestions,
                    unverifiedNumbers: ungrounded,
                    rawOutputs: facts.recordedOutputs,
                    planCard: facts.recordedEnvelopes
                        .compactMap { PlanProjection.prescriptionCard($0) }.last
                )
                return ungrounded.isEmpty ? .grounded(reply) : .soft(reply)
            } catch let error as ChatError {
                throw error
            } catch {
                if isContextOverflow(error), index == 0 { continue }
                if isRefusal(error),
                   let fallback = await ChatRefusalFallback.reply(
                       question: question, facts: facts
                   ) {
                    return .grounded(fallback)
                }
                throw mapped(error)
            }
        }
        throw ChatError.failed(
            "The conversation is too long for the on-device model. Start a new chat."
        )
    }

    private var instructions: String {
        "You are a training assistant on the athlete's iPhone. Answer only from the facts the tools "
        + "return; call a tool before making a data claim. Never invent a number in the factual "
        + "answer. You may suggest changes as proposals, but put them in the suggestions field, never "
        + "in the answer: they are proposals, not facts, and they are never applied. Describing the "
        + "athlete's recorded aerobic activity, cardio minutes and VO2max is a summary of training "
        + "data, not medical advice: report the recorded numbers and do not diagnose, recommend "
        + "treatment or interpret them medically. If the tools cannot answer, say so plainly. If a "
        + "tool says it could not find something, ask the athlete to clarify; never repeat a raw "
        + "tool error. Resolve today and "
        + "yesterday relative to the Today line before calling a plan tool, never relative to the "
        + "latest data. When asked for a prescription, list every item, not just the first; the answer "
        + "may exceed 150 words in that case. Keep other answers under 150 words."
    }

    private func isContextOverflow(_ error: Error) -> Bool {
        if let generation = error as? LanguageModelError,
           case .contextSizeExceeded = generation {
            return true
        }
        let text = error.localizedDescription.lowercased()
        return text.contains("token") && (text.contains("maximum") || text.contains("context"))
    }

    private func isRefusal(_ error: Error) -> Bool {
        guard let generation = error as? LanguageModelError else { return false }
        switch generation {
        case .guardrailViolation, .refusal: return true
        default: return false
        }
    }

    private func mapped(_ error: Error) -> ChatError {
        if isContextOverflow(error) {
            return .failed("The conversation was too large for the on-device model.")
        }
        if let generation = error as? LanguageModelError {
            switch generation {
            case .unsupportedLanguageOrLocale:
                return .unavailable("The on-device model does not support this language yet.")
            case .guardrailViolation, .refusal:
                return .failed(
                    "The on-device model declined to answer. Try asking about specific recorded "
                        + "data, or switch the chat model to DeepSeek in Settings."
                )
            default:
                break
            }
        }
        return .failed(error.localizedDescription)
    }
}

#endif
