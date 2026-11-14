import Foundation

public struct ExerciseDetailResponse: Decodable {
    public let exercise: ExerciseDetailSummary
    public let properties: [String: JSONValue]
    public let e1rmApplicable: Bool
    public let e1rm: ExerciseE1RMResponse?
    public let e1rmReason: String?
}

public struct ExerciseDetailSummary: Decodable, Equatable {
    public let id: String
    public let display: String
    public let pattern: String?
    public let source: String?
}

public struct ExerciseE1RMResponse: Decodable {
    public let exerciseId: String
    public let from: String
    public let to: String
    public let basis: String
    public let decay: String
    public let calibration: String
    public let points: [ExerciseE1RMPoint]
    public let degraded: [ExerciseE1RMDegraded]
    public let breaks: [ExerciseE1RMBreak]
    public let summary: ExerciseE1RMSummary
}

public struct ExerciseE1RMPoint: Decodable, Identifiable {
    public let date: String
    public let kg: Double
    public let rollingMedianKg: Double
    public let nWindow: Int

    public var id: String { date }
}

public struct ExerciseE1RMDegraded: Decodable, Identifiable {
    public let date: String
    public let kg: Double
    public let quality: String
    public let reason: String

    public var id: String { "\(date)-\(quality)" }
}

public struct ExerciseE1RMBreak: Decodable, Identifiable {
    public let date: String
    public let reason: String

    public var id: String { "\(date)-\(reason)" }
}

public struct ExerciseE1RMSummary: Decodable {
    public let n: Int
    public let status: String
    public let latest: ExerciseE1RMValue?
    public let best: ExerciseE1RMValue?
    public let recentMedianKg: Double?
    public let changeFromMedianKg: Double?
    public let trendStatement: String?
}

public struct ExerciseE1RMValue: Decodable, Equatable {
    public let date: String
    public let kg: Double
}

public struct ExerciseHistoryResponse: Decodable {
    public let exerciseId: String
    public let includedExercises: [ExerciseHistoryIncluded]
    public let limit: Int
    public let offset: Int
    public let total: Int
    public let hasMore: Bool
    public let start: String?
    public let end: String?
    public let sessions: [ExerciseHistorySession]
}

public struct ExerciseHistoryIncluded: Decodable, Identifiable, Equatable {
    public let id: String
    public let display: String
}

public struct ExerciseHistorySession: Decodable, Identifiable, Equatable {
    public let sessionId: String
    public let occurredOn: String
    public let sessionType: String?
    public let sets: [ExerciseHistorySet]

    public var id: String { sessionId }
}

public struct ExerciseHistorySet: Decodable, Identifiable, Equatable {
    public let setIndex: Int
    public let loadKg: Double?
    public let loadBasis: String?
    public let reps: Int?
    public let repsUnit: String?
    public let rir: Int?
    public let tonnageKg: Double?

    public var id: Int { setIndex }

    public var summary: String {
        let load = loadKg.map { "\(String(format: "%.1f", $0)) kg" } ?? "bodyweight"
        let reps = reps.map(String.init) ?? "?"
        var parts = ["\(load) × \(reps)"]
        if let rir { parts.append("RIR \(rir)") }
        if let loadBasis, loadBasis != "external" { parts.append(loadBasis) }
        return parts.joined(separator: " · ")
    }
}
