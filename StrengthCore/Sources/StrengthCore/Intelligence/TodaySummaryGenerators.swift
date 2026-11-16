import Foundation
#if canImport(FoundationModels) && os(iOS)
import FoundationModels
#endif

#if canImport(FoundationModels) && os(iOS)
/// The on-device shape of the Today card.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
@Generable
public struct GeneratedTodaySummary {
    @Guide(description: "Two or three sentences on where the athlete stands, taken from the facts only.")
    public var overview: String

    @Guide(description: "One or two warm sentences encouraging the next session, with no new claims about results.")
    public var encouragement: String

    public init(overview: String, encouragement: String) {
        self.overview = overview
        self.encouragement = encouragement
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct FoundationTodaySummaryGenerator: TodaySummaryGenerating {
    public init() {}

    public func availability() -> NarrativeAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable(NarrativeUnavailableReason.deviceNotEligible.message)
            case .appleIntelligenceNotEnabled:
                return .unavailable(NarrativeUnavailableReason.appleIntelligenceNotEnabled.message)
            case .modelNotReady:
                return .unavailable(NarrativeUnavailableReason.modelNotReady.message)
            @unknown default:
                return .unavailable("The on-device model is not available right now.")
            }
        }
    }

    public func generate(facts: TodaySummaryFacts) async throws -> TodaySummary {
        guard availability().isAvailable else {
            throw NarrativeError.unavailable(availability().reasonText)
        }
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: TodaySummaryPrompt.instructions
        )
        let response = try await session.respond(
            to: TodaySummaryPrompt.message(for: facts),
            generating: GeneratedTodaySummary.self
        )
        let content = response.content
        let summary = TodaySummary(
            overview: content.overview.trimmingCharacters(in: .whitespacesAndNewlines),
            encouragement: content.encouragement.trimmingCharacters(in: .whitespacesAndNewlines),
            model: .onDevice
        )
        try TodaySummaryValidator.validate(summary)
        return summary
    }
}
#else
public struct FoundationTodaySummaryGenerator: TodaySummaryGenerating {
    public init() {}

    public func availability() -> NarrativeAvailability {
        .unavailable("The on-device model needs iOS 27.")
    }

    public func generate(facts: TodaySummaryFacts) async throws -> TodaySummary {
        throw NarrativeError.unavailable("The on-device model is not available.")
    }
}
#endif

/// The external option. It uses the same facts as the on-device path and no tools: a summary needs
/// no retrieval, and a narrower request is a smaller disclosure.
public struct DeepSeekTodaySummaryGenerator: TodaySummaryGenerating {
    private let api: any DeepSeekCompleting
    private let keyPresent: Bool

    public init(api: any DeepSeekCompleting, keyPresent: Bool) {
        self.api = api
        self.keyPresent = keyPresent
    }

    public func availability() -> NarrativeAvailability {
        keyPresent
            ? .available
            : .unavailable("Add a DeepSeek API key in Settings to use this model.")
    }

    public func generate(facts: TodaySummaryFacts) async throws -> TodaySummary {
        guard keyPresent else {
            throw NarrativeError.unavailable(availability().reasonText)
        }
        let messages = [
            DeepSeekMessage(
                role: "system",
                content: TodaySummaryPrompt.instructions
                    + " Answer with exactly two lines: one starting with OVERVIEW: and one"
                    + " starting with ENCOURAGEMENT:."
            ),
            DeepSeekMessage(
                role: "user",
                content: TodaySummaryPrompt.message(for: facts, tokenLimit: 1_400)
            ),
        ]
        let result = try await api.complete(messages: messages, tools: [])
        guard let text = result.content else { throw DeepSeekError.badResponse }
        let summary = try Self.parse(text)
        try TodaySummaryValidator.validate(summary)
        return summary
    }

    static func parse(_ text: String) throws -> TodaySummary {
        var overview: String?
        var encouragement: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if lower.hasPrefix("overview:") {
                overview = String(line.dropFirst("overview:".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("encouragement:") {
                encouragement = String(line.dropFirst("encouragement:".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if let current = overview, encouragement == nil {
                overview = current + " " + line
            }
        }
        guard let overview, let encouragement,
              !overview.isEmpty, !encouragement.isEmpty else {
            throw DeepSeekError.badResponse
        }
        return TodaySummary(overview: overview, encouragement: encouragement, model: .deepSeek)
    }
}
