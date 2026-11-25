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

public struct BootstrapResponse: Codable, Equatable {
    public let apiVersion: String
    public let serverDate: String
    public let serverTime: String
    public let utcOffsetMinutes: Int
    public let serverTimezone: String
    public let capabilities: Capabilities
}

public struct Capabilities: Codable, Equatable {
    public let readiness: Bool
    public let prescription: Bool
    public let workoutWrite: Bool
    public let healthkit: Bool
    public let healthkitReadiness: Bool?
    public let healthkitActivity: Bool?
    public let offline: Bool
    public let readinessWrite: Bool?
    /// Additive INT-3 capability; nil on an older server that predates the route.
    public let intelligenceRead: Bool?

    public init(
        readiness: Bool,
        prescription: Bool,
        workoutWrite: Bool,
        healthkit: Bool,
        offline: Bool,
        readinessWrite: Bool? = nil,
        healthkitReadiness: Bool? = nil,
        healthkitActivity: Bool? = nil,
        intelligenceRead: Bool? = nil
    ) {
        self.readiness = readiness
        self.prescription = prescription
        self.workoutWrite = workoutWrite
        self.healthkit = healthkit
        self.healthkitReadiness = healthkitReadiness
        self.healthkitActivity = healthkitActivity
        self.offline = offline
        self.readinessWrite = readinessWrite
        self.intelligenceRead = intelligenceRead
    }
}

// MARK: - Today

/// Read-only programme context for Today (WP4). Every block is optional so an older server
/// or a profile without an anchor still decodes.
public struct ProgrammeHeader: Decodable, Equatable, Sendable {
    public let trainedWeek: Int?
    public let dup: ProgrammeHeaderDUP?
    public let deload: ProgrammeHeaderDeload?
    public let competition: ProgrammeHeaderCompetition?
}

public struct ProgrammeHeaderDUP: Decodable, Equatable, Sendable {
    public let enabled: Bool?
    public let cycleWeeks: Int?
    public let cycleWeek: Int?
    public let mainScheme: String?
    public let accessoryScheme: String?
}

public struct ProgrammeHeaderDeload: Decodable, Equatable, Sendable {
    public let calendarWeek: Int?
    public let status: String?
    public let trigger: String?
    public let reason: String?
}

public struct ProgrammeHeaderCompetition: Decodable, Equatable, Sendable {
    public let date: String?
    public let daysUntil: Int?
    public let window: String?
}

/// The one AFC-4 review nudge for Today (DEC-AFC-05, DEC-RESOLVER-26).
public struct NudgeEvidence: Decodable, Equatable, Sendable {
    public let evidenceId: String?
    public let source: String?
    public let method: String?
    public let gate: String?
    public let n: Int?
    public let limitations: [String]?
}

public struct Nudge: Decodable, Equatable, Identifiable, Sendable {
    public let key: String
    public let family: String
    public let statement: String
    public let gate: String?
    public let n: Int?
    public let evidenceId: String?
    public let observationId: String?
    public let category: String?
    public let source: String?
    public let evidence: NudgeEvidence?

    public var id: String { key }
}

public struct NudgeResponse: Decodable {
    public let onDate: String?
    public let nudge: Nudge?
}

public struct TodayResponse: Decodable {
    public let date: String
    public let readiness: ReadinessPayload?
    public let readinessScore: ReadinessScore?
    public let activeWorkout: WorkoutDetail?
    public let programmeHeader: ProgrammeHeader?
}

/// The existing server readiness payload is wider than Phase 1 shows; decode the fields this
/// screen uses and ignore settings/presets (they remain server-owned).
public struct ReadinessPayload: Decodable {
    public let onDate: String?
    public let known: Bool?
    /// The readiness registry version the server used for this day. The form can show it, but
    /// the schema endpoint remains the source for labels, scale and required fields.
    public let registryVersion: Int?
    public let score: ReadinessScore?
    public let contextFlags: [String]?
    public let hrvMs: Double?
    public let rhrBpm: Double?
    public let bodyweightKg: Double?
    public let sources: [String: String]?
    public let healthkit: [String: HealthKitReadinessProvenance]?

    /// The server sends `known: false` only when the day has no row at all and omits the key
    /// when any merged row exists. Row presence is not the same as a usable answer: a partial
    /// manual entry merges into a row whose score status is `insufficient`.
    public var hasEntry: Bool { known ?? true }

    /// A day counts as logged only when the server formed a readiness score. A merged row with
    /// too few core fields is `hasEntry` but `insufficient`, and the athlete still has readiness
    /// to finish; treating row presence as logged hid that in the daily reminder.
    public var isLogged: Bool { hasEntry && score?.status == "ready" }
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

public struct ReadinessScore: Codable, Equatable, Sendable {
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

public struct ReadinessComponent: Codable, Equatable, Sendable {
    public let field: String
    public let value: Double
    public let normalised: Double
    public let weight: Double
}

public struct ReadinessOverride: Codable, Equatable, Sendable {
    public let value: Double?
    public let reason: String?
}

public struct CategoryFactor: Codable, Equatable, Sendable {
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
    public let workoutId: String?
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
    /// Apple's own average and peak for the workout linked to this session; nil when no workout
    /// is linked, so "not recorded" never renders as a zero.
    public let heartRate: HistoryHeartRate?
    /// Display-only recovery values. They track effort rather than recovery capacity, so the
    /// caveat travels with them and nothing reads them back.
    public let hrRecovery: HistoryRecovery?
}

public struct HistoryRecovery: Decodable {
    public let setsWithValue: Int?
    public let caveat: String?
    public let finalSet: HistoryFinalSetRecovery?
}

public struct HistoryFinalSetRecovery: Decodable {
    public let hrEndBpm: Int?
    public let hrr60Bpm: Int?
    public let hrr120Bpm: Int?

    /// "−22 bpm at 1 min, −31 at 2 min · from the final set"; nil when neither horizon exists.
    public var summary: String? {
        var parts: [String] = []
        if let hrr60Bpm { parts.append(Self.phrase(hrr60Bpm, minutes: 1)) }
        if let hrr120Bpm { parts.append(Self.phrase(hrr120Bpm, minutes: 2)) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ") + " · from the final set"
    }

    private static func phrase(_ value: Int, minutes: Int) -> String {
        let signed = "\(value > 0 ? "−" : "")\(abs(value)) bpm"
        return "\(signed) at \(minutes) min"
    }
}

public struct HistoryHeartRate: Decodable {
    public let avgBpm: Int?
    public let maxBpm: Int?
    public let activityType: String?
    public let source: String?

    /// "128 avg / 165 max bpm", or whichever half Apple recorded; nil when neither exists.
    public var summary: String? {
        switch (avgBpm, maxBpm) {
        case let (avg?, max?): return "\(avg) avg / \(max) max bpm"
        case let (avg?, nil): return "\(avg) avg bpm"
        case let (nil, max?): return "\(max) max bpm"
        case (nil, nil): return nil
        }
    }
}

public struct HistoryDetailSet: Decodable, Identifiable {
    public let setId: Int?
    public let exerciseId: String
    public let loadKg: Double?
    public let reps: Int?
    public let rir: Int?
    public let velocityMps: Double?
    /// Heart-rate drop 60 s after this set. Display only: it tracks effort, not recovery, which
    /// is why the label carries the caveat instead of a rating.
    public let hrr60Bpm: Int?

    public var id: String { "\(setId ?? 0)-\(exerciseId)" }

    public var summary: String {
        let load = loadKg.map { String(format: "%.1f kg", $0) } ?? "bodyweight"
        let reps = reps.map(String.init) ?? "?"
        var value = "\(load) × \(reps)"
        if let rir { value += " · RIR \(rir)" }
        if let velocityMps, velocityMps > 0 {
            value += " · \(String(format: "%.2f", velocityMps)) m/s"
        }
        if let hrr60Bpm {
            value += " · HRR \(hrr60Bpm > 0 ? "−" : "") \(abs(hrr60Bpm)) bpm"
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
