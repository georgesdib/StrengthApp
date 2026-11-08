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
    let healthkitReadiness: Bool?
    let offline: Bool
    let readinessWrite: Bool?

    init(
        readiness: Bool,
        prescription: Bool,
        workoutWrite: Bool,
        healthkit: Bool,
        offline: Bool,
        readinessWrite: Bool? = nil,
        healthkitReadiness: Bool? = nil
    ) {
        self.readiness = readiness
        self.prescription = prescription
        self.workoutWrite = workoutWrite
        self.healthkit = healthkit
        self.healthkitReadiness = healthkitReadiness
        self.offline = offline
        self.readinessWrite = readinessWrite
    }
}

// MARK: - Today

struct TodayResponse: Decodable {
    let date: String
    let readiness: ReadinessPayload?
    let readinessScore: ReadinessScore?
    let activeWorkout: WorkoutDetail?
}

/// The existing server readiness payload is wider than Phase 1 shows; decode the fields this
/// screen uses and ignore settings/presets (they remain server-owned).
struct ReadinessPayload: Decodable {
    let onDate: String?
    let known: Bool?
    let score: ReadinessScore?
    let contextFlags: [String]?
    let hrvMs: Double?
    let rhrBpm: Double?
    let bodyweightKg: Double?
    let sources: [String: String]?
    let healthkit: [String: HealthKitReadinessProvenance]?
}

struct HealthKitReadinessProvenance: Decodable, Equatable {
    let value: Double
    let sampleId: String
    let sampleAt: String
    let sourceName: String
    let sourceBundleId: String?
    let sourceClass: String
    let sourceModel: String?
    let sourceManufacturer: String?
    let importedAt: String
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

// MARK: - History

struct HistoryResponse: Decodable {
    let total: Int
    let limit: Int
    let offset: Int
    let sessions: [HistorySession]
}

struct HistoryDetail: Decodable {
    let sessionId: String
    let occurredOn: String
    let workoutLabel: String?
    let sessionType: String?
    let dayGuess: String?
    let setCount: Int?
    let workingSetCount: Int?
    let exerciseCount: Int?
    let mainLifts: [String]?
    let tonnageKg: Double?
    let durationMin: Double?
    let durationBasis: String?
    let sets: [HistoryDetailSet]?
}

struct HistoryDetailSet: Decodable, Identifiable {
    let setId: Int?
    let exerciseId: String
    let loadKg: Double?
    let reps: Int?
    let rir: Int?
    let velocityMps: Double?

    var id: String { "\(setId ?? 0)-\(exerciseId)" }

    var summary: String {
        let load = loadKg.map { String(format: "%.1f kg", $0) } ?? "bodyweight"
        let reps = reps.map(String.init) ?? "?"
        var value = "\(load) × \(reps)"
        if let rir { value += " · RIR \(rir)" }
        if let velocityMps, velocityMps > 0 {
            value += " · \(String(format: "%.2f", velocityMps)) m/s"
        }
        return value
    }
}

struct HistorySession: Decodable, Identifiable {
    let sessionId: String
    let occurredOn: String
    let sessionType: String?
    let workoutLabel: String?
    let setCount: Int?
    let workingSetCount: Int?
    let tonnageKg: Double?
    let durationMin: Double?
    let durationBasis: String?
    let mainLifts: [String]?
    // SQLite stores this as 0/1 and the server passes it through as an integer.
    let needsReview: Int?
    let marks: Int?

    var id: String { sessionId }
}

// MARK: - Server error envelope

struct ServerErrorBody: Decodable {
    let error: String
    let code: String?
    let fields: [String: String]?
    let details: [String: JSONValue]?
}
