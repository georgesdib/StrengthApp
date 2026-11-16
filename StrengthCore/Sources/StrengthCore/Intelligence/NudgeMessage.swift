import Foundation

/// Everything a daily reminder is allowed to say about. Assembled by the app from data it already
/// holds; no metric is computed here and no training decision is made.
public struct NudgeFacts: Sendable, Equatable {
    public enum Readiness: Sendable, Equatable {
        case missing
        case logged(score: Double?)
    }

    public struct PlannedSession: Sendable, Equatable {
        public let label: String
        public let exerciseCount: Int
        public let focusName: String?
        public let focusSets: Int?
        public let focusReps: String?
        public let focusLoadKg: Double?

        public init(
            label: String,
            exerciseCount: Int,
            focusName: String? = nil,
            focusSets: Int? = nil,
            focusReps: String? = nil,
            focusLoadKg: Double? = nil
        ) {
            self.label = label
            self.exerciseCount = exerciseCount
            self.focusName = focusName
            self.focusSets = focusSets
            self.focusReps = focusReps
            self.focusLoadKg = focusLoadKg
        }
    }

    public let readiness: Readiness
    public let planned: PlannedSession?
    public let sessionInProgress: Bool

    public init(
        readiness: Readiness,
        planned: PlannedSession? = nil,
        sessionInProgress: Bool = false
    ) {
        self.readiness = readiness
        self.planned = planned
        self.sessionInProgress = sessionInProgress
    }

    /// Compact sentence form handed to the model. Data only; never instruction.
    public var factText: String {
        var lines: [String] = []
        switch readiness {
        case .missing:
            lines.append("Today's readiness is not logged.")
        case .logged(let score):
            if let score {
                lines.append("Today's readiness is logged with a score of \(Self.number(score)).")
            } else {
                lines.append("Today's readiness is logged.")
            }
        }
        if sessionInProgress {
            lines.append("A session is in progress right now.")
        }
        if let planned {
            lines.append("Planned session: \(planned.label), \(planned.exerciseCount) exercises.")
            if let name = planned.focusName {
                var line = "Lead exercise: \(name)"
                if let sets = planned.focusSets, let reps = planned.focusReps {
                    line += ", \(sets) sets of \(reps)"
                }
                if let load = planned.focusLoadKg, load > 0 {
                    line += " at \(Self.number(load)) kg"
                }
                lines.append(line + ".")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The only numbers a generated message may repeat.
    public var allowedNumbers: Set<String> {
        Set(NarrativeValidator.numbers(in: factText))
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// One rendered reminder. Presentation only: it carries no training data beyond the sentence.
public struct NudgeMessage: Sendable, Equatable {
    public enum Origin: String, Sendable, Equatable {
        case onDeviceModel
        case template
    }

    public static let titleLimit = 44
    public static let bodyLimit = 150

    public let title: String
    public let body: String
    public let origin: Origin

    public init(title: String, body: String, origin: Origin) {
        self.title = title
        self.body = body
        self.origin = origin
    }
}

/// Deterministic copy. This is a first-class outcome, not a silent fallback: it ships whenever the
/// model is unavailable, Apple Intelligence is off, or the model output fails validation.
public enum NudgeCopy {
    public static func message(for facts: NudgeFacts) -> NudgeMessage {
        if facts.sessionInProgress {
            return NudgeMessage(
                title: "Session in progress",
                body: "You are already training today. Finish strong.",
                origin: .template
            )
        }
        if let planned = facts.planned {
            if let name = planned.focusName,
               let load = planned.focusLoadKg, load > 0,
               let sets = planned.focusSets,
               let reps = planned.focusReps {
                let loadText = NudgeFacts.number(load)
                return NudgeMessage(
                    title: "\(name) is ready",
                    body: "\(sets)×\(reps) at \(loadText) kg is waiting. One session today — go and take it.",
                    origin: .template
                )
            }
            return NudgeMessage(
                title: "\(planned.label) is ready",
                body: "\(planned.exerciseCount) exercises are planned. Open the app and start when you are ready.",
                origin: .template
            )
        }
        if facts.readiness == .missing {
            return NudgeMessage(
                title: "Log readiness first",
                body: "Readiness is not logged yet. Two minutes now and today's session is ready to go.",
                origin: .template
            )
        }
        return NudgeMessage(
            title: "Ready when you are",
            body: "Today's session is one tap away. Open the app and I'll show you where it stands.",
            origin: .template
        )
    }

    /// Used for the tail of the horizon, where today's facts would already be stale.
    public static func generic() -> NudgeMessage {
        NudgeMessage(
            title: "Training check-in",
            body: "Open the app to see where the week stands and log today's readiness.",
            origin: .template
        )
    }
}

public protocol NudgeGenerating: Sendable {
    func availability() -> NarrativeAvailability
    func generate(facts: NudgeFacts) async throws -> NudgeMessage
}

public enum NudgeComposer {
    /// Model text when it validates, deterministic copy otherwise. There is nowhere to fall back to
    /// but the template, which is the point: no cloud model is reachable from this path.
    public static func compose(
        facts: NudgeFacts,
        generator: any NudgeGenerating
    ) async -> NudgeMessage {
        guard generator.availability().isAvailable else {
            return NudgeCopy.message(for: facts)
        }
        do {
            let message = try await generator.generate(facts: facts)
            try validate(message, facts: facts)
            return message
        } catch {
            return NudgeCopy.message(for: facts)
        }
    }

    public static func validate(_ message: NudgeMessage, facts: NudgeFacts) throws {
        guard message.title.count <= NudgeMessage.titleLimit,
              message.body.count <= NudgeMessage.bodyLimit else {
            throw NarrativeError.tooLong
        }
        try NarrativeValidator.validate(
            text: message.title,
            allowedNumbers: facts.allowedNumbers,
            maxLength: NudgeMessage.titleLimit
        )
        try NarrativeValidator.validate(
            text: message.body,
            allowedNumbers: facts.allowedNumbers,
            maxLength: NudgeMessage.bodyLimit
        )
    }
}

/// The next occurrences of a local time of day, DST-safe because the time is expressed as components.
public enum NudgeSchedule {
    public static func occurrences(
        hour: Int,
        minute: Int,
        count: Int,
        now: Date,
        calendar: Calendar = .current
    ) -> [Date] {
        guard count > 0 else { return [] }
        var dates: [Date] = []
        var dayOffset = 0
        var attempts = 0
        while dates.count < count && attempts < count + 4 {
            attempts += 1
            let offset = dayOffset
            dayOffset += 1
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            guard let candidate = calendar.date(
                bySettingHour: hour,
                minute: minute,
                second: 0,
                of: day,
                matchingPolicy: .nextTime
            ) else { continue }
            guard candidate > now else { continue }
            dates.append(candidate)
        }
        return dates
    }
}
