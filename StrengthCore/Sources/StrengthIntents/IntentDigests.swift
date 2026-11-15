import Foundation
import StrengthCore

/// One completed workout, read from the history list. Presentation only: every value is the
/// server's, and nothing here recomputes a metric.
public struct LastWorkoutSummary: Equatable {
    public let occurredOn: String
    public let sessionType: String?
    public let durationMin: Double?
    public let workingSets: Int?
    public let mainLifts: [String]?

    public init(
        occurredOn: String,
        sessionType: String?,
        durationMin: Double?,
        workingSets: Int?,
        mainLifts: [String]?
    ) {
        self.occurredOn = occurredOn
        self.sessionType = sessionType
        self.durationMin = durationMin
        self.workingSets = workingSets
        self.mainLifts = mainLifts
    }

    /// The sentence Siri speaks. It states what the history row contains and nothing else.
    public var dialog: String {
        let label = Self.label(sessionType)
        var text = "Your last workout"
        if let label { text += " (" + label + ")" }
        if let durationMin {
            text += " was " + Self.minutesText(durationMin) + " long"
        }
        text += " on " + occurredOn + "."
        if let workingSets, workingSets > 0 {
            text += " It had " + String(workingSets) + " working sets."
        }
        return text
    }

    /// A readable label for the stored session type; the raw value is used when it is unknown.
    public static func label(_ sessionType: String?) -> String? {
        guard let sessionType, !sessionType.isEmpty else { return nil }
        return sessionType
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    public static func minutesText(_ minutes: Double) -> String {
        let rounded = minutes.rounded()
        if abs(minutes - rounded) < 0.05 {
            return String(Int(rounded)) + " minutes"
        }
        return String(format: "%.1f minutes", minutes)
    }
}

/// One labelled value for a future snippet card. Plain text; no styling.
public struct IntentFactLine: Equatable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

// MARK: - Overview

public struct OverviewDigest: Equatable {
    public let windowWeeks: Int?
    public let completedSessions: Int?
    public let targetSessions: Int?
    public let adherencePct: Double?
    public let meanSessionMinutes: Double?
    public let readinessDaysObserved: Int?
    public let readinessWindowDays: Int?
    public let strengthGate: String?
    public let strengthPoints: Int?
    public let limitations: [String]

    public init(envelope: IntelligenceEnvelope) {
        let attendance = envelope.facts["attendance"]?.value.objectValue
        let duration = attendance?["duration"]?.objectValue
        let readiness = envelope.facts["readiness_coverage"]?.value.objectValue
        let trend = envelope.facts["strength_trend"]?.value.objectValue

        windowWeeks = envelope.period.weeks
        completedSessions = attendance?["completed"]?.intValue
        targetSessions = attendance?["target"]?.intValue
        adherencePct = attendance?["pct"]?.doubleValue
        meanSessionMinutes = duration?["mean_min"]?.doubleValue
        readinessDaysObserved = readiness?["observed_days"]?.intValue
        readinessWindowDays = readiness?["window_days"]?.intValue
        strengthGate = envelope.facts["strength_trend"]?.gate
        strengthPoints = trend?["points"]?.arrayValue?.count
        limitations = envelope.limitations
    }

    public var dialog: String {
        var parts: [String] = []
        if let completedSessions, let targetSessions {
            let window = windowWeeks.map { String($0) + "-week window: " } ?? ""
            parts.append(window + String(completedSessions) + " of " + String(targetSessions) + " sessions completed")
        } else if let completedSessions {
            parts.append(String(completedSessions) + " sessions completed")
        }
        if let meanSessionMinutes {
            parts.append("average session " + LastWorkoutSummary.minutesText(meanSessionMinutes))
        }
        if let readinessDaysObserved, let readinessWindowDays {
            parts.append("readiness logged on " + String(readinessDaysObserved) + " of " + String(readinessWindowDays) + " days")
        }
        if parts.isEmpty { return "There is not enough training data in this window yet." }
        return "Training overview: " + parts.joined(separator: ", ") + "."
    }

    public var lines: [IntentFactLine] {
        var lines: [IntentFactLine] = []
        if let completedSessions, let targetSessions {
            lines.append(.init(label: "Sessions", value: String(completedSessions) + " of " + String(targetSessions)))
        }
        if let adherencePct {
            lines.append(.init(label: "Adherence", value: String(Int(adherencePct.rounded())) + "%"))
        }
        if let meanSessionMinutes {
            lines.append(.init(label: "Mean session", value: LastWorkoutSummary.minutesText(meanSessionMinutes)))
        }
        if let readinessDaysObserved, let readinessWindowDays {
            lines.append(.init(label: "Readiness days", value: String(readinessDaysObserved) + " of " + String(readinessWindowDays)))
        }
        if let strengthPoints {
            lines.append(.init(label: "Strength points", value: String(strengthPoints)))
        }
        return lines
    }
}

// MARK: - Average session duration

/// The overview envelope's duration block: a window aggregate, never a per-session value.
public struct AverageDurationDigest: Equatable {
    public let weeks: Int
    public let sessionCount: Int?
    public let meanMinutes: Double?
    public let measuredCount: Int?
    public let measuredMeanMinutes: Double?

    public init(envelope: IntelligenceEnvelope, weeks: Int) {
        let duration = envelope.facts["attendance"]?.value.objectValue?["duration"]?.objectValue
        self.weeks = weeks
        sessionCount = duration?["n"]?.intValue
        meanMinutes = duration?["mean_min"]?.doubleValue
        measuredCount = duration?["measured_n"]?.intValue
        measuredMeanMinutes = duration?["measured_mean_min"]?.doubleValue
    }

    /// The spoken sentence. It always names the window and the sample size, because the mean is a
    /// window aggregate and mixes measured and estimated durations.
    public var dialog: String {
        let window = "the last " + String(weeks) + (weeks == 1 ? " week" : " weeks")
        guard let meanMinutes else {
            return "No session durations were recorded over " + window + "."
        }
        var text = "Your average workout over " + window + " was " + LastWorkoutSummary.minutesText(meanMinutes)
        if let sessionCount, sessionCount > 0 {
            text += ", based on " + String(sessionCount) + (sessionCount == 1 ? " session" : " sessions")
            if let measuredCount, measuredCount > 0, let measuredMeanMinutes {
                text += ", " + String(measuredCount) + " measured (average "
                    + LastWorkoutSummary.minutesText(measuredMeanMinutes) + ")"
            }
        }
        return text + "."
    }

    public var lines: [IntentFactLine] {
        var lines: [IntentFactLine] = []
        if let meanMinutes {
            lines.append(.init(label: "Average", value: LastWorkoutSummary.minutesText(meanMinutes)))
        }
        if let sessionCount {
            lines.append(.init(label: "Sessions", value: String(sessionCount)))
        }
        if let measuredMeanMinutes, let measuredCount {
            lines.append(.init(
                label: "Measured",
                value: LastWorkoutSummary.minutesText(measuredMeanMinutes) + " (" + String(measuredCount) + ")"
            ))
        }
        return lines
    }
}

// MARK: - Weekly review

public struct WeeklyReviewDigest: Equatable {
    public struct ProgressionRow: Equatable {
        public let display: String
        public let direction: String?
        public let changeKg: Double?
        public let n: Int?
    }

    public let weekStart: String
    public let weekEnd: String
    public let completedSessions: Int?
    public let targetSessions: Int?
    public let workingSets: Int?
    public let progression: [ProgressionRow]
    public let observations: [String]
    public let limitations: [String]

    public init(envelope: IntelligenceEnvelope) {
        let activity = envelope.facts["activity"]?.value.objectValue
        weekStart = envelope.period.start
        weekEnd = envelope.period.end
        completedSessions = activity?["completed_sessions"]?.intValue
        targetSessions = activity?["target_sessions"]?.intValue
        workingSets = activity?["working_sets"]?.intValue
        progression = (envelope.facts["progression"]?.value.arrayValue ?? []).compactMap { row in
            guard let object = row.objectValue, let display = object["display"]?.stringValue else { return nil }
            return ProgressionRow(
                display: display,
                direction: object["direction"]?.stringValue,
                changeKg: object["change_kg"]?.doubleValue,
                n: object["n"]?.intValue
            )
        }
        observations = (envelope.observations ?? []).map(\.text)
        limitations = envelope.limitations
    }

    public var dialog: String {
        var parts: [String] = []
        if let completedSessions, let targetSessions {
            parts.append(String(completedSessions) + " of " + String(targetSessions) + " sessions")
        } else if let completedSessions {
            parts.append(String(completedSessions) + " sessions")
        }
        if let workingSets {
            parts.append(String(workingSets) + " working sets")
        }
        var text = "Week of " + weekStart + ": " + (parts.isEmpty ? "no sessions recorded" : parts.joined(separator: ", "))
        if let first = progression.first {
            var movement = first.display
            if let changeKg = first.changeKg {
                movement += " up " + String(format: "%.1f", abs(changeKg)) + " kg"
            } else if let direction = first.direction {
                movement += " " + direction
            }
            text += ". " + movement + "."
        } else if let observation = observations.first {
            text += ". " + observation
        }
        return text
    }
}

// MARK: - Progression

public struct ProgressionDigest: Equatable {
    public let exerciseDisplay: String?
    public let direction: String?
    public let changeKg: Double?
    public let sessions: Int?
    public let observations: Int?

    public init(envelope: IntelligenceEnvelope) {
        let exercise = envelope.facts["exercise"]?.value.objectValue
        let summary = envelope.facts["summary"]?.value.objectValue
        let series = envelope.facts["series"]?.value.objectValue
        exerciseDisplay = exercise?["display"]?.stringValue
        direction = summary?["direction"]?.stringValue
        changeKg = summary?["change_kg"]?.doubleValue
        sessions = summary?["n"]?.intValue
        observations = series?["observations"]?.arrayValue?.count
    }

    public func dialog(fallbackName: String? = nil) -> String {
        let name = exerciseDisplay ?? fallbackName ?? "This exercise"
        if let changeKg = self.changeKg, let direction = self.direction {
            let sign = direction.lowercased() == "down" ? "-" : "+"
            let n = sessions.map { " over " + String($0) + " sessions" } ?? ""
            return name + ": strength " + direction + " " + sign + String(format: "%.1f", abs(changeKg)) + " kg" + n + "."
        }
        if let direction = self.direction {
            return name + ": strength trend is " + direction + "."
        }
        return name + ": not enough comparable sessions for a trend yet."
    }
}
