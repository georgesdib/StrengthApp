import Foundation

// MARK: - Pairing

struct DeviceSummary: Decodable, Equatable {
    let deviceId: String
    let label: String
}

struct PairResponse: Decodable {
    let apiVersion: String
    let device: DeviceSummary
    let token: String
    let serverDate: String
    let serverTime: String
    let utcOffsetMinutes: Int
    let serverTimezone: String
}

// MARK: - Bootstrap

struct BootstrapResponse: Decodable, Equatable {
    let apiVersion: String
    let serverDate: String
    let serverTime: String
    let utcOffsetMinutes: Int
    let serverTimezone: String
    let capabilities: Capabilities
}

struct Capabilities: Decodable, Equatable {
    let readiness: Bool
    let prescription: Bool
    let workoutWrite: Bool
    let healthkit: Bool
    let offline: Bool
}

// MARK: - Today

struct TodayResponse: Decodable {
    let date: String
    let readiness: ReadinessPayload?
    let readinessScore: ReadinessScore?
    let activeWorkout: ActiveWorkout?
}

/// The existing server readiness payload is wider than Phase 1 shows; decode the fields this
/// screen uses and ignore settings/presets (they remain server-owned).
struct ReadinessPayload: Decodable {
    let onDate: String?
    let known: Bool?
    let score: ReadinessScore?
    let contextFlags: [String]?
}

struct ReadinessScore: Decodable {
    let onDate: String?
    let status: String
    let score: Double?
    let basis: String?
    let components: [ReadinessComponent]?
    let overrides: [String: ReadinessOverride]?
    let categoryScores: [String: Double]?
    let categoryFactors: [String: CategoryFactor]?
    let contextFlags: [String]?
    let deviceSuppressed: Bool?
}

struct ReadinessComponent: Decodable {
    let field: String
    let value: Double
    let normalised: Double
    let weight: Double
}

struct ReadinessOverride: Decodable {
    let value: Double?
    let reason: String?
}

struct CategoryFactor: Decodable {
    let factor: Double
    let rirBump: Int
}

/// Only the summary is decoded; plan/sets remain server detail and are ignored here.
struct ActiveWorkout: Decodable {
    let workoutId: String
    let forDate: String?
    let sessionType: String?
    let status: String?
    let startedAt: String?
}

// MARK: - History

struct HistoryResponse: Decodable {
    let total: Int
    let limit: Int
    let offset: Int
    let sessions: [HistorySession]
}

struct HistorySession: Decodable, Identifiable {
    let sessionId: String
    let occurredOn: String
    let sessionType: String?
    let workoutLabel: String?
    let setCount: Int?
    let workingSetCount: Int?
    let tonnageKg: Double?
    let mainLifts: [String]?
    // SQLite stores this as 0/1 and the server passes it through as an integer.
    let needsReview: Int?
    let marks: Int?

    var id: String { sessionId }
}

// MARK: - Server error envelope

struct ServerErrorBody: Decodable {
    let error: String
    let fields: [String: String]?
}
