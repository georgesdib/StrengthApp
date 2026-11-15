import Foundation
#if canImport(FoundationModels) && os(iOS)
import FoundationModels
#endif

/// Compact text for one capability. No evidence arrays, provenance internals or raw health values.
public protocol IntelligenceCapabilityProviding: Sendable {
    func trainingOverview(asOf: String?, windowWeeks: Int) async throws -> String
    func exerciseProgression(exerciseID: String, windowDays: Int) async throws -> String
    func weeklyReview(weekEnd: String?) async throws -> String
    func sessionDetails(workoutID: String) async throws -> String
    func readinessStatus(from: String, to: String) async throws -> String
}

public enum NarrativeUnavailableReason: String, Sendable {
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady

    public var message: String {
        switch self {
        case .deviceNotEligible:
            return "This iPhone does not support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in Settings to use explanations."
        case .modelNotReady:
            return "The on-device model is still downloading. Try again later."
        }
    }
}

public enum NarrativeBudget {
    public static func estimateTokens(_ text: String) -> Int {
        (text.count + 3) / 4
    }

    /// Keep the highest-value lines within the budget. Returns nil when even the core cannot fit.
    public static func fit(_ facts: String, tokenLimit: Int = 1_400) -> String? {
        var lines = facts.split(separator: "\n").map(String.init)
        func text(_ lines: [String]) -> String { lines.joined(separator: "\n") }
        if estimateTokens(text(lines)) <= tokenLimit { return text(lines) }
        for prefix in ["limitation:", "missing:", "observation:"] {
            lines.removeAll { $0.hasPrefix(prefix) }
            if estimateTokens(text(lines)) <= tokenLimit { return text(lines) }
        }
        while estimateTokens(text(lines)) > tokenLimit, lines.count > 4 {
            lines.removeLast()
        }
        return estimateTokens(text(lines)) <= tokenLimit ? text(lines) : nil
    }
}

#if canImport(FoundationModels) && os(iOS)
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
@Generable
public struct NarrativeToolQuery {
    @Guide(description: "Optional identifier or hint. Pass an empty string when none is needed.")
    public var query: String

    public init(query: String = "") {
        self.query = query
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public enum IntelligenceTools {
    public static func make(provider: any IntelligenceCapabilityProviding) -> [any Tool] {
        [
            TrainingOverviewTool(provider: provider),
            ExerciseProgressionTool(provider: provider),
            WeeklyReviewTool(provider: provider),
            SessionDetailsTool(provider: provider),
            ReadinessStatusTool(provider: provider),
        ]
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct TrainingOverviewTool: Tool {
    public typealias Arguments = NarrativeToolQuery
    private let provider: any IntelligenceCapabilityProviding
    public init(provider: any IntelligenceCapabilityProviding) { self.provider = provider }
    public let name = "training_overview"
    public let description = "Read-only four-week training overview: compliance, performance, volume and readiness coverage. Use it for a broader context."
    public func call(arguments: NarrativeToolQuery) async throws -> String {
        do {
            return try await provider.trainingOverview(asOf: nil, windowWeeks: 4)
        } catch {
            return "The overview could not be loaded right now."
        }
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct ExerciseProgressionTool: Tool {
    public typealias Arguments = NarrativeToolQuery
    private let provider: any IntelligenceCapabilityProviding
    public init(provider: any IntelligenceCapabilityProviding) { self.provider = provider }
    public let name = "exercise_progression"
    public let description = "Read-only e1RM progression for one exercise. Pass an exact canonical id such as competition_squat, bench_press or trap_bar_deadlift, or an empty string when the question is not lift-specific."
    public func call(arguments: NarrativeToolQuery) async throws -> String {
        let exercise = arguments.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !exercise.isEmpty else {
            return "No exercise was specified, so no progression is available."
        }
        do {
            return try await provider.exerciseProgression(exerciseID: exercise, windowDays: 84)
        } catch {
            return "No progression was found for '\(exercise)'. Ask the athlete which lift they mean; "
                + "examples are competition_squat, bench_press and trap_bar_deadlift."
        }
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct WeeklyReviewTool: Tool {
    public typealias Arguments = NarrativeToolQuery
    private let provider: any IntelligenceCapabilityProviding
    public init(provider: any IntelligenceCapabilityProviding) { self.provider = provider }
    public let name = "weekly_review"
    public let description = "Read-only deterministic Monday-Sunday review: activity, adherence, sessions, progression, volume, readiness coverage and programme state."
    public func call(arguments: NarrativeToolQuery) async throws -> String {
        do {
            return try await provider.weeklyReview(weekEnd: nil)
        } catch {
            return "The weekly review could not be loaded right now."
        }
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct SessionDetailsTool: Tool {
    public typealias Arguments = NarrativeToolQuery
    private let provider: any IntelligenceCapabilityProviding
    public init(provider: any IntelligenceCapabilityProviding) { self.provider = provider }
    public let name = "session_details"
    public let description = "Read-only detail for one completed workout. Pass the workout id, or an empty string when no workout is in question."
    public func call(arguments: NarrativeToolQuery) async throws -> String {
        let workout = arguments.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workout.isEmpty else {
            return "No workout was specified, so no session detail is available."
        }
        do {
            return try await provider.sessionDetails(workoutID: workout)
        } catch {
            return "No session was found for that workout id."
        }
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct ReadinessStatusTool: Tool {
    public typealias Arguments = NarrativeToolQuery
    private let provider: any IntelligenceCapabilityProviding
    public init(provider: any IntelligenceCapabilityProviding) { self.provider = provider }
    public let name = "readiness_status"
    public let description = "Read-only readiness score and coverage for the last seven days. Raw health fields are not returned by this tool."
    public func call(arguments: NarrativeToolQuery) async throws -> String {
        do {
            return try await provider.readinessStatus(from: "", to: "")
        } catch {
            return "Readiness could not be loaded right now."
        }
    }
}
#endif
