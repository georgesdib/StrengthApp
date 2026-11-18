import Foundation

/// Deterministic answer for a health-flavoured question the on-device model refuses.
///
/// The text comes from the server's longevity facts and is shown verbatim; this adds no
/// interpretation and no training policy. The fallback is deliberately narrow so a refusal on an
/// unrelated topic still surfaces a clear error instead of an unrelated health summary.
public enum ChatRefusalFallback {
    private static let terms = [
        "longevity", "cardio", "aerobic", "vo2", "vo₂", "heart", "endurance", "fitness",
    ]

    /// True when the question is about recorded aerobic or longevity data.
    public static func asksAboutLongevity(_ question: String) -> Bool {
        let text = question.lowercased()
        return terms.contains { text.contains($0) }
    }

    /// The recorded longevity facts, or nil when the question is unrelated or no facts exist.
    ///
    /// A tool call earlier in the turn already recorded the facts; only fetch when the model
    /// refused before calling the tool. The caller maps a nil result to a clear error.
    public static func reply(
        question: String,
        facts: any ChatFactsProviding
    ) async -> ChatReply? {
        guard asksAboutLongevity(question) else { return nil }
        let recorded = facts.recordedOutputs.last {
            $0.source.caseInsensitiveCompare("longevity") == .orderedSame
        }
        let text: String
        if let recorded {
            text = recorded.text
        } else if let fetched = try? await facts.longevityAssessment(includeTimeInZone: false) {
            text = fetched
        } else {
            return nil
        }
        let factsText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !factsText.isEmpty,
              factsText != "No longevity data is available right now." else {
            return nil
        }
        return ChatReply(
            text: "The on-device model declined to interpret this, so here are your recorded "
                + "longevity facts:\n\n" + factsText
                + "\n\nThe Longevity panel has the full breakdown.",
            sources: facts.recordedSources.isEmpty ? ["longevity"] : facts.recordedSources,
            rawOutputs: facts.recordedOutputs
        )
    }
}
