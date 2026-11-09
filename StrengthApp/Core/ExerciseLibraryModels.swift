import Foundation
import StrengthCore

struct ExerciseDetailResponse: Decodable {
    let exercise: ExerciseDetailSummary
    let properties: [String: JSONValue]
    let e1rmApplicable: Bool
    let e1rm: ExerciseE1RMResponse?
    let e1rmReason: String?
}

struct ExerciseDetailSummary: Decodable, Equatable {
    let id: String
    let display: String
    let pattern: String?
    let source: String?
}

struct ExerciseE1RMResponse: Decodable {
    let exerciseId: String
    let from: String
    let to: String
    let basis: String
    let decay: String
    let calibration: String
    let points: [ExerciseE1RMPoint]
    let degraded: [ExerciseE1RMDegraded]
    let breaks: [ExerciseE1RMBreak]
    let summary: ExerciseE1RMSummary
}

struct ExerciseE1RMPoint: Decodable, Identifiable {
    let date: String
    let kg: Double
    let rollingMedianKg: Double
    let nWindow: Int

    var id: String { date }
}

struct ExerciseE1RMDegraded: Decodable, Identifiable {
    let date: String
    let kg: Double
    let quality: String
    let reason: String

    var id: String { "\(date)-\(quality)" }
}

struct ExerciseE1RMBreak: Decodable, Identifiable {
    let date: String
    let reason: String

    var id: String { "\(date)-\(reason)" }
}

struct ExerciseE1RMSummary: Decodable {
    let n: Int
    let status: String
    let latest: ExerciseE1RMValue?
    let best: ExerciseE1RMValue?
    let recentMedianKg: Double?
    let changeFromMedianKg: Double?
    let trendStatement: String?
}

struct ExerciseE1RMValue: Decodable, Equatable {
    let date: String
    let kg: Double
}

struct ExerciseHistoryResponse: Decodable {
    let exerciseId: String
    let includedExercises: [ExerciseHistoryIncluded]
    let limit: Int
    let offset: Int
    let total: Int
    let hasMore: Bool
    let start: String?
    let end: String?
    let sessions: [ExerciseHistorySession]
}

struct ExerciseHistoryIncluded: Decodable, Identifiable, Equatable {
    let id: String
    let display: String
}

struct ExerciseHistorySession: Decodable, Identifiable, Equatable {
    let sessionId: String
    let occurredOn: String
    let sessionType: String?
    let sets: [ExerciseHistorySet]

    var id: String { sessionId }
}

struct ExerciseHistorySet: Decodable, Identifiable, Equatable {
    let setIndex: Int
    let loadKg: Double?
    let loadBasis: String?
    let reps: Int?
    let repsUnit: String?
    let rir: Int?
    let tonnageKg: Double?

    var id: Int { setIndex }

    var summary: String {
        let load = loadKg.map { "\(String(format: "%.1f", $0)) kg" } ?? "bodyweight"
        let reps = reps.map(String.init) ?? "?"
        var parts = ["\(load) × \(reps)"]
        if let rir { parts.append("RIR \(rir)") }
        if let loadBasis, loadBasis != "external" { parts.append(loadBasis) }
        return parts.joined(separator: " · ")
    }
}
