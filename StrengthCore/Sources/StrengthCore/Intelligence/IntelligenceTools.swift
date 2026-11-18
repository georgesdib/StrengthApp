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
    /// Aerobic adequacy, VO2max status and volume headroom, as compact facts.
    func longevityAssessment(includeTimeInZone: Bool) async throws -> String
}

public extension IntelligenceCapabilityProviding {
    /// Default keeps purpose-built test doubles and future providers compiling. The app's provider
    /// implements the real call; a build without it says so rather than inventing numbers.
    func longevityAssessment(includeTimeInZone: Bool) async throws -> String {
        "No longevity facts are available in this build."
    }
}

/// Safe, model-facing classification of a failed capability call.
public enum PlanQuery {
    /// Resolves "today"/"yesterday" or an ISO date. Returns nil for anything else (an id).
    public static func isoDate(
        from value: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let target: Date?
        switch lower {
        case "today", "": target = lower == "today" ? now : nil
        case "yesterday": target = calendar.date(byAdding: .day, value: -1, to: now)
        default: target = nil
        }
        if let target {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: target)
        }
        let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, Int(parts[0]) != nil,
              parts[1].count == 2, Int(parts[1]) != nil,
              parts[2].count == 2, Int(parts[2]) != nil else {
            return nil
        }
        return trimmed
    }
}

public protocol PlanFactsProviding: Sendable {
    func prescription(query: String) async throws -> String
    func programmeSummary(query: String) async throws -> String
    func adherence(query: String) async throws -> String
}

public enum CapabilityFailure: String, Sendable, Equatable, CaseIterable {
    case notFound
    case invalidIdentifier
    case unauthorized
    case unavailable
    case server
    case unknown

    public init(_ error: Error) {
        guard let api = error as? APIError else {
            self = .unknown
            return
        }
        switch api {
        case .transport:
            self = .unavailable
        case .unauthorized, .forbidden:
            self = .unauthorized
        case .http(let status, _, _):
            self = Self.from(status: status)
        case .server(let status, _, _, _, _):
            self = Self.from(status: status)
        default:
            self = .unknown
        }
    }

    private static func from(status: Int) -> CapabilityFailure {
        switch status {
        case 404: return .notFound
        case 400, 422: return .invalidIdentifier
        case 401, 403: return .unauthorized
        case 500...: return .server
        default: return .unknown
        }
    }
}

/// Records classifications without leaking them into the conversation.
public final class ToolFailureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CapabilityFailure] = []

    public init() {}

    public var failures: [CapabilityFailure] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    public func record(_ failure: CapabilityFailure) {
        lock.lock(); defer { lock.unlock() }
        storage.append(failure)
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        storage = []
    }
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
    public static func make(
        provider: any IntelligenceCapabilityProviding,
        failureLog: ToolFailureLog? = nil,
        includePlan: Bool = false,
        includeBase: Bool = true,
        planNames: Set<String>? = nil
    ) -> [any Tool] {
        var tools: [any Tool] = includeBase ? [
            TrainingOverviewTool(provider: provider, failureLog: failureLog),
            ExerciseProgressionTool(provider: provider, failureLog: failureLog),
            WeeklyReviewTool(provider: provider, failureLog: failureLog),
            SessionDetailsTool(provider: provider, failureLog: failureLog),
            ReadinessStatusTool(provider: provider, failureLog: failureLog),
        ] : []
        if includePlan {
            let planTools: [(String, any Tool)] = [
                ("prescription", PrescriptionTool(provider: provider, failureLog: failureLog)),
                ("programme_summary", ProgrammeSummaryTool(provider: provider, failureLog: failureLog)),
                ("adherence", AdherenceTool(provider: provider, failureLog: failureLog)),
            ]
            let selected = planNames ?? Set(planTools.map(\.0))
            tools += planTools.filter { selected.contains($0.0) }.map(\.1)
        }
        return tools
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct TrainingOverviewTool: Tool {
    public typealias Arguments = NarrativeToolQuery
    private let provider: any IntelligenceCapabilityProviding
    private let failureLog: ToolFailureLog?
    public init(provider: any IntelligenceCapabilityProviding, failureLog: ToolFailureLog? = nil) {
        self.provider = provider
        self.failureLog = failureLog
    }
    public let name = "training_overview"
    public let description = "Read-only four-week training overview: compliance, performance, volume and readiness coverage. Use it for a broader context."
    public func call(arguments: NarrativeToolQuery) async throws -> String {
        do {
            return try await provider.trainingOverview(asOf: nil, windowWeeks: 4)
        } catch {
            let failure = CapabilityFailure(error)
            failureLog?.record(failure)
            switch failure {
            case .unauthorized:
                return "The overview could not be accessed. The pairing may need attention."
            case .unavailable, .server:
                return "The overview data is temporarily unavailable. Try again."
            case .notFound:
                return "No overview data was found."
            case .invalidIdentifier, .unknown:
                return "The overview could not be loaded right now."
            }
        }
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct ExerciseProgressionTool: Tool {
    public typealias Arguments = NarrativeToolQuery
    private let provider: any IntelligenceCapabilityProviding
    private let failureLog: ToolFailureLog?
    public init(provider: any IntelligenceCapabilityProviding, failureLog: ToolFailureLog? = nil) {
        self.provider = provider
        self.failureLog = failureLog
    }
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
            let failure = CapabilityFailure(error)
            failureLog?.record(failure)
            switch failure {
            case .notFound, .invalidIdentifier:
                return "No progression was found for '\(exercise)'. Ask the athlete which lift they mean; "
                    + "examples are competition_squat, bench_press and trap_bar_deadlift."
            case .unauthorized:
                return "Progression data could not be accessed. The pairing may need attention."
            case .unavailable, .server:
                return "Progression data is temporarily unavailable. Try again."
            case .unknown:
                return "Progression data could not be loaded right now."
            }
        }
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct WeeklyReviewTool: Tool {
    public typealias Arguments = NarrativeToolQuery
    private let provider: any IntelligenceCapabilityProviding
    private let failureLog: ToolFailureLog?
    public init(provider: any IntelligenceCapabilityProviding, failureLog: ToolFailureLog? = nil) {
        self.provider = provider
        self.failureLog = failureLog
    }
    public let name = "weekly_review"
    public let description = "Read-only deterministic Monday-Sunday review: activity, adherence, sessions, progression, volume, readiness coverage and programme state."
    public func call(arguments: NarrativeToolQuery) async throws -> String {
        do {
            return try await provider.weeklyReview(weekEnd: nil)
        } catch {
            let failure = CapabilityFailure(error)
            failureLog?.record(failure)
            switch failure {
            case .unauthorized:
                return "The weekly review could not be accessed. The pairing may need attention."
            case .unavailable, .server:
                return "The weekly review is temporarily unavailable. Try again."
            case .notFound:
                return "No weekly review data was found."
            case .invalidIdentifier, .unknown:
                return "The weekly review could not be loaded right now."
            }
        }
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct SessionDetailsTool: Tool {
    public typealias Arguments = NarrativeToolQuery
    private let provider: any IntelligenceCapabilityProviding
    private let failureLog: ToolFailureLog?
    public init(provider: any IntelligenceCapabilityProviding, failureLog: ToolFailureLog? = nil) {
        self.provider = provider
        self.failureLog = failureLog
    }
    public let name = "session_details"
    public let description = "Read-only detail for one completed workout. Pass a workout id if known, or an empty string for the most recent completed session."
    public func call(arguments: NarrativeToolQuery) async throws -> String {
        let workout = arguments.query.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            return try await provider.sessionDetails(workoutID: workout)
        } catch {
            let failure = CapabilityFailure(error)
            failureLog?.record(failure)
            switch failure {
            case .notFound:
                return "No session was found for that workout."
            case .invalidIdentifier:
                return "That workout id is not valid."
            case .unauthorized:
                return "Session data could not be accessed. The pairing may need attention."
            case .unavailable, .server:
                return "Session data is temporarily unavailable. Try again."
            case .unknown:
                return "Session data could not be loaded right now."
            }
        }
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct PrescriptionTool: Tool {
    public typealias Arguments = NarrativeToolQuery
    private let provider: any IntelligenceCapabilityProviding
    private let failureLog: ToolFailureLog?
    public init(provider: any IntelligenceCapabilityProviding, failureLog: ToolFailureLog? = nil) {
        self.provider = provider
        self.failureLog = failureLog
    }
    public let name = "prescription"
    public let description = "Read-only training prescription. Convert relative dates to YYYY-MM-DD (for example yesterday becomes a date), or pass a prescription id; an empty string asks for the current prescription."
    public func call(arguments: NarrativeToolQuery) async throws -> String {
        guard let plan = provider as? any PlanFactsProviding else {
            return "Plan data is not available in this build."
        }
        do {
            return try await plan.prescription(query: arguments.query)
        } catch {
            let failure = CapabilityFailure(error)
            failureLog?.record(failure)
            switch failure {
            case .unauthorized: return "The prescription could not be accessed. The pairing may need attention."
            case .unavailable, .server: return "Prescription data is temporarily unavailable. Try again."
            case .notFound: return "No prescription was found for that date."
            case .invalidIdentifier, .unknown: return "The prescription could not be loaded right now."
            }
        }
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct ProgrammeSummaryTool: Tool {
    public typealias Arguments = NarrativeToolQuery
    private let provider: any IntelligenceCapabilityProviding
    private let failureLog: ToolFailureLog?
    public init(provider: any IntelligenceCapabilityProviding, failureLog: ToolFailureLog? = nil) {
        self.provider = provider
        self.failureLog = failureLog
    }
    public let name = "programme_summary"
    public let description = "Read-only training programme block summary. Pass a date (YYYY-MM-DD) or an empty string for today."
    public func call(arguments: NarrativeToolQuery) async throws -> String {
        guard let plan = provider as? any PlanFactsProviding else {
            return "Plan data is not available in this build."
        }
        do {
            return try await plan.programmeSummary(query: arguments.query)
        } catch {
            let failure = CapabilityFailure(error)
            failureLog?.record(failure)
            switch failure {
            case .unauthorized: return "The programme could not be accessed. The pairing may need attention."
            case .unavailable, .server: return "Programme data is temporarily unavailable. Try again."
            case .notFound: return "No programme was found for that date."
            case .invalidIdentifier, .unknown: return "The programme could not be loaded right now."
            }
        }
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct AdherenceTool: Tool {
    public typealias Arguments = NarrativeToolQuery
    private let provider: any IntelligenceCapabilityProviding
    private let failureLog: ToolFailureLog?
    public init(provider: any IntelligenceCapabilityProviding, failureLog: ToolFailureLog? = nil) {
        self.provider = provider
        self.failureLog = failureLog
    }
    public let name = "adherence"
    public let description = "Read-only adherence analysis. Pass a number of weeks or a date (YYYY-MM-DD); an empty string uses twelve weeks."
    public func call(arguments: NarrativeToolQuery) async throws -> String {
        guard let plan = provider as? any PlanFactsProviding else {
            return "Plan data is not available in this build."
        }
        do {
            return try await plan.adherence(query: arguments.query)
        } catch {
            let failure = CapabilityFailure(error)
            failureLog?.record(failure)
            switch failure {
            case .unauthorized: return "Adherence could not be accessed. The pairing may need attention."
            case .unavailable, .server: return "Adherence data is temporarily unavailable. Try again."
            case .notFound: return "No adherence data was found."
            case .invalidIdentifier, .unknown: return "Adherence could not be loaded right now."
            }
        }
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct ReadinessStatusTool: Tool {
    public typealias Arguments = NarrativeToolQuery
    private let provider: any IntelligenceCapabilityProviding
    private let failureLog: ToolFailureLog?
    public init(provider: any IntelligenceCapabilityProviding, failureLog: ToolFailureLog? = nil) {
        self.provider = provider
        self.failureLog = failureLog
    }
    public let name = "readiness_status"
    public let description = "Read-only readiness score and coverage for the last seven days. Raw health fields are not returned by this tool."
    public func call(arguments: NarrativeToolQuery) async throws -> String {
        do {
            return try await provider.readinessStatus(from: "", to: "")
        } catch {
            let failure = CapabilityFailure(error)
            failureLog?.record(failure)
            switch failure {
            case .unauthorized:
                return "Readiness could not be accessed. The pairing may need attention."
            case .unavailable, .server:
                return "Readiness data is temporarily unavailable. Try again."
            case .notFound:
                return "No readiness data was found."
            case .invalidIdentifier, .unknown:
                return "Readiness could not be loaded right now."
            }
        }
    }
}
#endif
