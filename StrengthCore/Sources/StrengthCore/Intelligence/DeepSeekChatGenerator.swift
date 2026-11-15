import Foundation

/// Grounding for any chat provider. Returns digits that are not in the returned facts.
public enum ChatGrounding {
    public static func unverified(
        text: String,
        question: String,
        history: [ChatMessage],
        envelopes: [IntelligenceEnvelope]
    ) -> [String] {
        let questionTime = ChatPrompt.timeNumbers(question: question, history: history)
        let allowed = ChatPrompt.allowedNumbers(
            data: NarrativeContext.allowedNumbers(in: envelopes),
            questionTime: questionTime,
            answer: text
        )
        return NarrativeValidator.numbers(in: text).filter {
            !NarrativeValidator.isGrounded($0, allowedNumbers: allowed)
        }
    }
}

public enum DeepSeekTools {
    public static func specs(includePlan: Bool = false) -> [DeepSeekTool] {
        var tools = baseSpecs
        if includePlan {
            tools += [
                tool(name: "prescription", description: "Read-only training prescription. Pass a date (YYYY-MM-DD) or prescription id; an empty string asks for the current prescription.", query: "Date, prescription id, or empty string."),
                tool(name: "programme_summary", description: "Read-only training programme block summary. Pass a date (YYYY-MM-DD) or an empty string for today.", query: "Date or empty string."),
                tool(name: "adherence", description: "Read-only adherence analysis. Pass a number of weeks or a date (YYYY-MM-DD); an empty string uses twelve weeks.", query: "Weeks, date, or empty string."),
            ]
        }
        return tools
    }

    private static let baseSpecs: [DeepSeekTool] = [
        tool(
            name: "training_overview",
            description: "Read-only four-week training overview: compliance, performance, volume and readiness coverage.",
            query: "Optional hint; pass an empty string."
        ),
        tool(
            name: "exercise_progression",
            description: "Read-only e1RM progression for one exercise. Pass an exact canonical id such as competition_squat, bench_press or trap_bar_deadlift.",
            query: "Canonical exercise id."
        ),
        tool(
            name: "weekly_review",
            description: "Read-only deterministic Monday-Sunday review: activity, adherence, sessions, progression, volume, readiness coverage and programme state.",
            query: "Optional hint; pass an empty string."
        ),
        tool(
            name: "session_details",
            description: "Read-only detail for one completed workout. Pass a workout id if known, or an empty string for the most recent completed session.",
            query: "Workout id or empty string."
        ),
        tool(
            name: "readiness_status",
            description: "Read-only readiness score and coverage for the last seven days.",
            query: "Optional hint; pass an empty string."
        ),
    ]

    private static func tool(name: String, description: String, query: String) -> DeepSeekTool {
        DeepSeekTool(
            function: .init(
                name: name,
                description: description,
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string(query),
                        ]),
                    ]),
                ])
            )
        )
    }

    public static func query(from arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = object["query"] as? String else {
            return ""
        }
        return query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func execute(
        name: String,
        query: String,
        provider: any IntelligenceCapabilityProviding,
        failureLog: ToolFailureLog?
    ) async -> String {
        do {
            switch name {
            case "training_overview":
                return try await provider.trainingOverview(asOf: nil, windowWeeks: 4)
            case "exercise_progression":
                guard !query.isEmpty else {
                    return "No exercise was specified, so no progression is available."
                }
                return try await provider.exerciseProgression(exerciseID: query, windowDays: 84)
            case "weekly_review":
                return try await provider.weeklyReview(weekEnd: nil)
            case "session_details":
                return try await provider.sessionDetails(workoutID: query)
            case "readiness_status":
                return try await provider.readinessStatus(from: "", to: "")
            case "prescription":
                guard let plan = provider as? any PlanFactsProviding else {
                    return "Plan data is not available in this build."
                }
                return try await plan.prescription(query: query)
            case "programme_summary":
                guard let plan = provider as? any PlanFactsProviding else {
                    return "Plan data is not available in this build."
                }
                return try await plan.programmeSummary(query: query)
            case "adherence":
                guard let plan = provider as? any PlanFactsProviding else {
                    return "Plan data is not available in this build."
                }
                return try await plan.adherence(query: query)
            default:
                return "No such training tool is available."
            }
        } catch {
            let failure = CapabilityFailure(error)
            failureLog?.record(failure)
            switch (name, failure) {
            case (_, .unauthorized):
                return "Training data could not be accessed. The pairing may need attention."
            case (_, .unavailable), (_, .server):
                return "Training data is temporarily unavailable. Try again."
            case ("exercise_progression", .notFound), ("exercise_progression", .invalidIdentifier):
                return "No progression was found for '\(query)'. Ask which lift is meant; examples are "
                    + "competition_squat, bench_press and trap_bar_deadlift."
            case ("session_details", .notFound):
                return "No session was found for that workout."
            case ("session_details", .invalidIdentifier):
                return "That workout id is not valid."
            default:
                return "Training data could not be loaded right now."
            }
        }
    }
}

@MainActor
public final class DeepSeekChatGenerator: TrainingChatGenerating {
    private let api: any DeepSeekCompleting
    private let keyPresent: Bool
    private let facts: any ChatFactsProviding
    private let includePlan: Bool
    private let failureLog = ToolFailureLog()

    public init(
        api: any DeepSeekCompleting,
        keyPresent: Bool,
        facts: any ChatFactsProviding,
        includePlan: Bool = false
    ) {
        self.api = api
        self.keyPresent = keyPresent
        self.facts = facts
        self.includePlan = includePlan
    }

    public func availability() -> NarrativeAvailability {
        keyPresent
            ? .available
            : .unavailable("Add a DeepSeek API key in Settings to use this model.")
    }

    public func reply(to question: String, history: [ChatMessage]) async throws -> ChatReply {
        guard keyPresent else {
            throw ChatError.unavailable(availability().reasonText)
        }
        facts.resetRecord()
        failureLog.reset()

        var messages: [DeepSeekMessage] = [
            DeepSeekMessage(role: "system", content: instructions),
        ]
        for message in history.suffix(6) {
            messages.append(
                DeepSeekMessage(
                    role: message.role == .user ? "user" : "assistant",
                    content: message.text
                )
            )
        }
        messages.append(DeepSeekMessage(role: "user", content: question))

        var toolRounds = 0
        for attempt in 0..<2 {
            while toolRounds < 4 {
                let result = try await api.complete(
                    messages: messages, tools: DeepSeekTools.specs(includePlan: includePlan)
                )
                if !result.toolCalls.isEmpty {
                    messages.append(
                        DeepSeekMessage(
                            role: "assistant",
                            content: result.content,
                            toolCalls: result.toolCalls
                        )
                    )
                    for call in result.toolCalls {
                        let output = await DeepSeekTools.execute(
                            name: call.function.name,
                            query: DeepSeekTools.query(from: call.function.arguments),
                            provider: facts,
                            failureLog: failureLog
                        )
                        messages.append(
                            DeepSeekMessage(
                                role: "tool", content: output, toolCallID: call.id
                            )
                        )
                    }
                    toolRounds += 1
                    continue
                }
                guard let raw = result.content, !raw.isEmpty else {
                    throw ChatError.failed("DeepSeek returned an empty answer.")
                }
                let parsed = Self.parse(raw)
                let text = parsed.answer
                let suggestions = Array(parsed.suggestions.prefix(3)).map {
                    String($0.prefix(240))
                }
                guard text.count <= 2_500 else { throw ChatError.tooLong }
                let envelopes = facts.recordedEnvelopes
                if envelopes.isEmpty, failureLog.failures.contains(.unauthorized) {
                    throw ChatError.unavailable(
                        "Your training data could not be accessed. Check the pairing."
                    )
                }
                if envelopes.isEmpty,
                   failureLog.failures.contains(where: { $0 == .unavailable || $0 == .server }) {
                    throw ChatError.failed("Your training data is temporarily unavailable. Try again.")
                }
                let unverified = ChatGrounding.unverified(
                    text: text, question: question, history: history, envelopes: envelopes
                )
                if unverified.isEmpty {
                    return ChatReply(
                        text: text, sources: facts.recordedSources, suggestions: suggestions
                    )
                }
                if attempt == 0 {
                    messages.append(DeepSeekMessage(role: "assistant", content: text))
                    messages.append(
                        DeepSeekMessage(
                            role: "user",
                            content: "Correction: the answer used numbers that are not in the facts: "
                                + "\(unverified.joined(separator: ", ")). Rewrite it using only numbers "
                                + "from the tool results, or say you cannot verify them."
                        )
                    )
                    break
                }
                return ChatReply(
                    text: text,
                    sources: facts.recordedSources,
                    suggestions: suggestions,
                    unverifiedNumbers: unverified
                )
            }
            if toolRounds >= 4 {
                throw ChatError.failed("DeepSeek used too many tool steps.")
            }
        }
        throw ChatError.failed("The answer could not be generated.")
    }

    private struct AnswerPayload: Decodable {
        let answer: String
        let suggestions: [String]?
    }

    private static func parse(_ raw: String) -> (answer: String, suggestions: [String]) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
            return (raw, [])
        }
        let json = String(text[start...end])
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(AnswerPayload.self, from: data),
              !payload.answer.isEmpty else {
            return (raw, [])
        }
        return (payload.answer, payload.suggestions ?? [])
    }

    private var instructions: String {
        "You are a training assistant. Answer only from the facts the tools return; call a tool "
        + "before making a data claim. Never invent a number in the answer. You may suggest changes "
        + "and discuss medical considerations, but put them in the suggestions list, never in the "
        + "answer: they are proposals, not facts, and they are never applied. If the tools cannot "
        + "answer, say so plainly. Return a JSON object with keys answer (string) and suggestions "
        + "(array of strings, empty when none). Convert today and yesterday to YYYY-MM-DD before calling "
        + "a plan tool. When asked for a prescription, list every item, not just the first. Keep the "
        + "answer under 150 words."
    }
}
