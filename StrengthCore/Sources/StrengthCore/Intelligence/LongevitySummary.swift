import Foundation

/// The deterministic half of the longevity card.
///
/// It formats the server's envelope into one headline and one fact line. It performs no arithmetic
/// beyond reading the numbers the server sent, and it never states a verdict: the WHO band is
/// context, not a target (DEC-LONGEVITY-01).
public struct LongevitySummary: Sendable, Equatable {
    public let headline: String
    public let vo2maxLine: String
    /// Compact facts text for a host model. Numbers only; the model writes the prose.
    public let detail: String
    public let relation: String
    public let status: String

    public init?(envelope: IntelligenceEnvelope) {
        guard envelope.capability == "get_longevity_assessment" else { return nil }
        status = envelope.status
        let lastWeek = envelope.facts["last_week"]?.value.objectValue
        let current = envelope.facts["current_week"]?.value.objectValue
        let vo2max = envelope.facts["vo2max"]?.value.objectValue
        relation = lastWeek?["relation"]?.stringValue ?? "unknown"

        let equivalent = lastWeek?["equivalent_minutes"]?.numberValue
        let remaining = lastWeek?["remaining_minutes"]?.numberValue
        let reference = lastWeek?["reference"]?.objectValue
        let minimum = reference?["min_minutes"]?.numberValue ?? 150
        let maximum = reference?["max_minutes"]?.numberValue ?? 300

        switch relation {
        case "inside" where equivalent != nil:
            headline = "\(Self.minutes(equivalent ?? 0)) moderate-equivalent minutes last week "
                + "— inside the \(Self.whole(minimum))–\(Self.whole(maximum)) reference."
        case "below" where equivalent != nil:
            let short = remaining.map { Self.minutes($0) } ?? "some"
            headline = "\(Self.minutes(equivalent ?? 0)) moderate-equivalent minutes last week "
                + "— \(short) short of the \(Self.whole(minimum))-minute reference."
        case "unknown" where envelope.status == "insufficient":
            headline = "Last week's activity could not be classified well enough to compare "
                + "with the reference."
        default:
            headline = envelope.status == "no_data"
                ? "No classified aerobic activity recorded last week."
                : "There is not enough classified activity to compare with the reference yet."
        }

        let vo2Status = vo2max?["status"]?.stringValue ?? "absent"
        let vo2Value = vo2max?["value"]?.numberValue
        let vo2Date = vo2max?["measured_on"]?.stringValue
        switch vo2Status {
        case "current" where vo2Value != nil:
            vo2maxLine = "VO₂max \(Self.oneDecimal(vo2Value ?? 0)) ml/kg/min · \(vo2Date ?? "")"
        case "stale" where vo2Value != nil:
            vo2maxLine = "VO₂max \(Self.oneDecimal(vo2Value ?? 0)) · \(vo2Date ?? "") (stale)"
        default:
            vo2maxLine = "No VO₂max measurement recorded."
        }

        var facts: [String] = []
        if let equivalent {
            facts.append("Completed week: \(Self.minutes(equivalent)) moderate-equivalent minutes "
                + "(reference \(Self.whole(minimum))–\(Self.whole(maximum)); context only, not a target).")
        }
        if let current, let currentMinutes = current["equivalent_minutes"]?.numberValue {
            let days = current["days_remaining"]?.intValue ?? 0
            facts.append("Current week: \(Self.minutes(currentMinutes)) so far, \(days) days left.")
        }
        switch vo2Status {
        case "current", "stale":
            facts.append("VO2max \(Self.oneDecimal(vo2Value ?? 0)) ml/kg/min measured "
                + "\(vo2Date ?? "unknown date") (\(vo2Status)).")
        default:
            facts.append("No VO2max measurement has been recorded; that is not evidence of poor fitness.")
        }
        if let patterns = envelope.facts["patterns"]?.value.objectValue,
           let perPattern = patterns["per_pattern"]?.objectValue, !perPattern.isEmpty {
            let short = perPattern.compactMap { key, value -> String? in
                guard let row = value.objectValue,
                      let gap = row["short"]?.numberValue, gap > 0 else { return nil }
                return "\(key) \(Self.minutes(gap)) sets short"
            }.sorted()
            if !short.isEmpty {
                facts.append("Volume headroom: " + short.joined(separator: "; ") + ".")
            }
        }
        if let missing = envelope.missing.first {
            facts.append("Missing: \(missing)")
        }
        detail = facts.joined(separator: " ")
    }

    private static func minutes(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static func whole(_ value: Double) -> String { String(Int(value.rounded())) }

    private static func oneDecimal(_ value: Double) -> String { String(format: "%.1f", value) }
}
