import Foundation

// MARK: - Pairing

public struct DeviceSummary: Decodable, Equatable {
    public let deviceId: String
    public let label: String
}

public struct PairResponse: Decodable {
    public let apiVersion: String
    public let device: DeviceSummary
    public let token: String
    public let serverDate: String
    public let serverTime: String
    public let utcOffsetMinutes: Int
    public let serverTimezone: String
}

// MARK: - Bootstrap

public struct BootstrapResponse: Decodable, Equatable {
    public let apiVersion: String
    public let serverDate: String
    public let serverTime: String
    public let utcOffsetMinutes: Int
    public let serverTimezone: String
    public let capabilities: Capabilities
}

public struct Capabilities: Decodable, Equatable {
    public let readiness: Bool
    public let prescription: Bool
    public let workoutWrite: Bool
    public let healthkit: Bool
    public let healthkitReadiness: Bool?
    public let offline: Bool
    public let readinessWrite: Bool?

    public init(
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

public struct TodayResponse: Decodable {
    public let date: String
    public let readiness: ReadinessPayload?
    public let readinessScore: ReadinessScore?
    public let activeWorkout: WorkoutDetail?
}

/// The existing server readiness payload is wider than Phase 1 shows; decode the fields this
/// screen uses and ignore settings/presets (they remain server-owned).
public struct ReadinessPayload: Decodable {
    public let onDate: String?
    public let known: Bool?
    public let score: ReadinessScore?
    public let contextFlags: [String]?
    public let hrvMs: Double?
    public let rhrBpm: Double?
    public let bodyweightKg: Double?
    public let sources: [String: String]?
    public let healthkit: [String: HealthKitReadinessProvenance]?
}

public struct HealthKitReadinessProvenance: Decodable, Equatable {
    public let value: Double
    public let sampleId: String
    public let sampleAt: String
    public let sourceName: String
    public let sourceBundleId: String?
    public let sourceClass: String
    public let sourceModel: String?
    public let sourceManufacturer: String?
    public let importedAt: String
}

public struct ReadinessScore: Decodable {
    public let onDate: String?
    public let status: String
    public let score: Double?
    public let basis: String?
    public let components: [ReadinessComponent]?
    public let overrides: [String: ReadinessOverride]?
    public let categoryScores: [String: Double]?
    public let categoryFactors: [String: CategoryFactor]?
    public let contextFlags: [String]?
    public let deviceSuppressed: Bool?
}

public struct ReadinessComponent: Decodable {
    public let field: String
    public let value: Double
    public let normalised: Double
    public let weight: Double
}

public struct ReadinessOverride: Decodable {
    public let value: Double?
    public let reason: String?
}

public struct CategoryFactor: Decodable {
    public let factor: Double
    public let rirBump: Int
}

// MARK: - History

public struct HistoryResponse: Decodable {
    public let total: Int
    public let limit: Int
    public let offset: Int
    public let sessions: [HistorySession]
}

public struct HistoryDetail: Decodable {
    public let sessionId: String
    public let occurredOn: String
    public let workoutLabel: String?
    public let sessionType: String?
    public let dayGuess: String?
    public let setCount: Int?
    public let workingSetCount: Int?
    public let exerciseCount: Int?
    public let mainLifts: [String]?
    public let tonnageKg: Double?
    public let durationMin: Double?
    public let durationBasis: String?
    public let sets: [HistoryDetailSet]?
}

public struct HistoryDetailSet: Decodable, Identifiable {
    public let setId: Int?
    public let exerciseId: String
    public let loadKg: Double?
    public let reps: Int?
    public let rir: Int?
    public let velocityMps: Double?

    public var id: String { "\(setId ?? 0)-\(exerciseId)" }

    public var summary: String {
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

public struct HistorySession: Decodable, Identifiable {
    public let sessionId: String
    public let occurredOn: String
    public let sessionType: String?
    public let workoutLabel: String?
    public let setCount: Int?
    public let workingSetCount: Int?
    public let tonnageKg: Double?
    public let durationMin: Double?
    public let durationBasis: String?
    public let mainLifts: [String]?
    // SQLite stores this as 0/1 and the server passes it through as an integer.
    public let needsReview: Int?
    public let marks: Int?

    public var id: String { sessionId }
}

// MARK: - Server error envelope

public struct ServerErrorBody: Decodable {
    public let error: String
    public let code: String?
    public let fields: [String: String]?
    public let details: [String: JSONValue]?
}
