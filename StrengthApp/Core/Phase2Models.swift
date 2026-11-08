import Foundation

// MARK: - JSON helpers

/// A small JSON value used for server conflict details. The server only sends JSON here.
enum JSONValue: Decodable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unsupported JSON value"
            )
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

// MARK: - Prescription

struct PrescriptionPlan: Codable {
    let forDate: String?
    let sessionType: String?
    let sessionLabel: String?
    let items: [PrescriptionItem]
    let warnings: [String]?
    let issues: [String]?
}

struct PrescriptionItem: Codable, Identifiable {
    let orderIndex: Int?
    let exerciseId: String?
    let sets: Int?
    let repsLow: Int?
    let repsHigh: Int?
    let loadKg: Double?
    let loadBasis: String?
    let rirTarget: Int?
    let effortModel: String?
    let refs: [String]?
    let restS: Int?
    let essential: Bool?

    var id: String { "\(orderIndex ?? 0)-\(exerciseId ?? "")" }

    var loadLabel: String {
        guard let loadKg, loadKg > 0 else { return "bodyweight" }
        return String(format: "%.1f kg", loadKg)
    }

    var repsLabel: String {
        switch (repsLow, repsHigh) {
        case let (low?, high?) where low == high: return "\(low)"
        case let (low?, high?): return "\(low)-\(high)"
        case let (low?, nil): return "\(low)+"
        default: return "—"
        }
    }

    var effortLabel: String {
        if effortModel == "quality" { return "quality" }
        guard let rirTarget else { return "—" }
        return "RIR \(rirTarget)"
    }
}

// MARK: - Plan request (R7)

/// Workout settings sent with a request. The phone chooses an input; the server owns the plan.
struct PlanSettings: Codable, Equatable {
    var sessionType: String = "auto"
    var minimumSession: Bool = false
    var minimumTargetMinutes: Int?
    /// nil lets the server/resolver decide; true asks for top set/back-off; false asks for
    /// straight sets. The server still owns eligibility and every load/repetition decision.
    var topSet: Bool? = nil
}

/// The 202 acknowledgement: the request exists, the plan does not yet.
struct PlanRequestAck: Decodable {
    let issuedPlanId: String
    let status: String
    let forDate: String
    let requestExpiresAt: String
    let planExpiresAt: String?
    let retryAfterMs: Int?
    let settings: PlanSettings?
}

struct PlanErrorBody: Decodable, Equatable {
    let code: String
    let message: String
}

/// The authoritative read: status is queued, building, ready, error or none.
struct PlansStateResponse: Decodable {
    let status: String
    let issuedPlanId: String?
    let forDate: String?
    let elapsedSeconds: Int?
    let requestExpiresAt: String?
    let planExpiresAt: String?
    let retryAfterMs: Int?
    let settings: PlanSettings?
    let sessionType: String?
    let plan: PrescriptionPlan?
    let readiness: ReadinessScore?
    let warnings: [String]?
    let error: PlanErrorBody?

    static let none = PlansStateResponse(
        status: "none", issuedPlanId: nil, forDate: nil, elapsedSeconds: nil,
        requestExpiresAt: nil, planExpiresAt: nil, retryAfterMs: nil, settings: nil,
        sessionType: nil, plan: nil, readiness: nil, warnings: nil, error: nil
    )

    /// A ready state is the only one that can be previewed and started.
    var issuedPlan: IssuedPlanResponse? {
        guard status == "ready", let plan else { return nil }
        return IssuedPlanResponse(
            issuedPlanId: issuedPlanId ?? "",
            forDate: forDate ?? "",
            sessionType: sessionType ?? plan.sessionType ?? "",
            expiresAt: planExpiresAt ?? "",
            plan: plan,
            readiness: readiness,
            warnings: warnings ?? []
        )
    }
}

/// The preview the owner starts. R7: an unstarted plan is a preview, not a prescription.
struct IssuedPlanResponse: Identifiable {
    let issuedPlanId: String
    let forDate: String
    let sessionType: String
    let expiresAt: String
    let plan: PrescriptionPlan
    let readiness: ReadinessScore?
    let warnings: [String]

    var id: String { issuedPlanId }
}

/// Permissive envelope for a journalled prescription response: a Phase 2 receipt may return the
/// old synchronous body, so only the shared identifier is read here.
struct PlanAckEnvelope: Decodable {
    let issuedPlanId: String?
    let status: String?
}

/// Progress of an in-flight request, shown while the dispatcher builds.
struct PlanProgress: Equatable {
    var issuedPlanId: String
    var status: String
    var elapsedSeconds: Int
    var settings: PlanSettings
}

// MARK: - Workout

struct WorkoutDetail: Codable, Identifiable {
    let workoutId: String
    let prescriptionId: String?
    let forDate: String?
    let sessionType: String?
    let status: String
    let plan: PrescriptionPlan?
    let sets: [WorkoutSet]?
    let forms: [WorkoutForm]?
    let elapsedSeconds: Int?
    let sessionRpe: Double?
    let startedAt: String?

    var id: String { workoutId }

    /// The API returns the latest rating per exercise; use it to distinguish an initial rating
    /// from a correction without inventing a second local history.
    func formRating(for exerciseId: String) -> WorkoutForm? {
        forms?.first { $0.exerciseId == exerciseId }
    }

    func replacing(sets: [WorkoutSet]? = nil, forms: [WorkoutForm]? = nil) -> WorkoutDetail {
        WorkoutDetail(
            workoutId: workoutId,
            prescriptionId: prescriptionId,
            forDate: forDate,
            sessionType: sessionType,
            status: status,
            plan: plan,
            sets: sets ?? self.sets,
            forms: forms ?? self.forms,
            elapsedSeconds: elapsedSeconds,
            sessionRpe: sessionRpe,
            startedAt: startedAt
        )
    }
}

struct WorkoutSet: Codable, Identifiable {
    let setId: Int?
    let exerciseId: String
    let setIndex: Int?
    let planItemIndex: Int?
    let loadKg: Double?
    let reps: Int?
    let rir: Int?
    let velocity: Double?
    let source: String?
    let repsDetail: WorkoutRepDetail?
    let repSummary: WorkoutRepSummary?

    var id: String { "\(setId ?? 0)-\(exerciseId)-\(setIndex ?? 0)" }

    var isPendingLocal: Bool { (setId ?? 0) < 0 }

    var loadLabel: String {
        guard let loadKg, loadKg > 0 else { return "bodyweight" }
        return String(format: "%.1f kg", loadKg)
    }

    var velocityLabel: String? {
        guard let velocity, velocity > 0 else { return nil }
        return String(format: "%.2f m/s", velocity)
    }
}

struct WorkoutRep: Codable, Identifiable {
    let repIndex: Int
    let velocityMps: Double

    var id: Int { repIndex }
}

struct WorkoutRepDetail: Codable {
    let reps: [WorkoutRep]
    let source: String?
    let batchId: String?
}

struct WorkoutRepSummary: Codable {
    let count: Int
    let first: Double
    let last: Double
    let mean: Double
    let min: Double
    let max: Double
    let lossAbs: Double
    let lossPct: Double?
}

struct WorkoutForm: Codable, Identifiable {
    let formId: Int?
    let workoutId: String?
    let exerciseId: String
    let rating: Int
    let note: String?

    var id: String { "\(formId ?? 0)-\(workoutId ?? "")-\(exerciseId)" }
}

// MARK: - Progress

struct ProgressResponse: Decodable {
    let onDate: String
    let coverage: ProgressCoverage
    let performance: ProgressPerformance
    let volume: [ProgressVolume]
    let back: ProgressBack
    let attendance: ProgressAttendance
    let note: String?
}

struct ProgressCoverage: Decodable {
    let sessions: Int
    let withSrpe: Int
    let pct: Double
}

struct ProgressPerformance: Decodable {
    let points: [ProgressPoint]
    let latest: ProgressPoint?
    let medianRatio: Double?
    let n: Int
}

struct ProgressPoint: Decodable, Identifiable {
    let date: String
    let ratio: Double
    let lifts: Int

    var id: String { date }
}

struct ProgressVolume: Decodable, Identifiable {
    let pattern: String
    let average: Double
    let status: String
    // Untargeted patterns have no MRV landmark; the server sends null.
    let mrv: Double?

    var id: String { pattern }
}

struct ProgressBack: Decodable {
    let level: Int?
    let date: String?
}

struct ProgressAttendance: Decodable {
    let weeks: Int
    let from: String
    let to: String
    let completed: Int
    let target: Int?
    let pct: Double?
    let note: String?
}


enum RepVelocityParseError: LocalizedError, Equatable {
    case invalidNumber(String)
    case tooMany(reps: Int, provided: Int)

    var errorDescription: String? {
        switch self {
        case .invalidNumber(let token):
            return "Per-rep velocity '\(token)' must be a positive number."
        case .tooMany(let reps, let provided):
            return "Enter at most \(reps) per-rep velocities (\(provided) provided)."
        }
    }
}

enum RepVelocityParser {
    /// Parse comma/space-separated m/s values for reps 1..n. Blank input means no detail.
    static func parse(_ text: String, reps: Int) throws -> [RepVelocity]? {
        let tokens = text
            .split { $0 == "," || $0.isWhitespace }
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        guard reps > 0 else {
            throw RepVelocityParseError.tooMany(reps: reps, provided: tokens.count)
        }
        guard tokens.count <= reps else {
            throw RepVelocityParseError.tooMany(reps: reps, provided: tokens.count)
        }
        return try tokens.enumerated().map { offset, token in
            guard let value = Double(token), value.isFinite, value > 0 else {
                throw RepVelocityParseError.invalidNumber(token)
            }
            return RepVelocity(repIndex: offset + 1, velocityMps: value)
        }
    }
}

// MARK: - Requests

struct ReadinessWriteRequest: Encodable, Equatable {
    let values: [String: Double]
    let note: String?
}

struct IssuePrescriptionRequest: Encodable {
    let readinessAck: Bool
    let confirmations: [String: Bool]?
    let settings: PlanSettings?
}

struct StartWorkoutRequest: Encodable {
    let issuedPlanId: String
}

struct RepVelocity: Codable, Equatable, Identifiable {
    let repIndex: Int
    let velocityMps: Double

    var id: Int { repIndex }
}

struct AddSetRequest: Codable, Equatable {
    let exerciseId: String
    let loadKg: Double?
    let reps: Int
    let rir: Int?
    let velocityMps: Double?
    let setIndex: Int?
    let planItemIndex: Int?
    let repVelocities: [RepVelocity]?
    let performedAt: String?

    init(
        exerciseId: String,
        loadKg: Double?,
        reps: Int,
        rir: Int?,
        velocityMps: Double?,
        setIndex: Int?,
        planItemIndex: Int?,
        repVelocities: [RepVelocity]? = nil,
        performedAt: String? = nil
    ) {
        self.exerciseId = exerciseId
        self.loadKg = loadKg
        self.reps = reps
        self.rir = rir
        self.velocityMps = velocityMps
        self.setIndex = setIndex
        self.planItemIndex = planItemIndex
        self.repVelocities = repVelocities
        self.performedAt = performedAt
    }
}

struct FormRatingRequest: Codable, Equatable {
    let exerciseId: String
    let rating: Int
    let note: String?
}

struct CompleteWorkoutRequest: Codable, Equatable {
    let sessionRpe: Double?
    let notRecorded: Bool
    let durationMin: Double?
    let notes: String?
    let endedAt: String?
    let productivity: Int?

    init(
        sessionRpe: Double?,
        notRecorded: Bool,
        durationMin: Double?,
        notes: String?,
        endedAt: String? = nil,
        productivity: Int? = nil
    ) {
        self.sessionRpe = sessionRpe
        self.notRecorded = notRecorded
        self.durationMin = durationMin
        self.notes = notes
        self.endedAt = endedAt
        self.productivity = productivity
    }
}

struct EmptyRequest: Encodable {}

// MARK: - Exercise catalogue and plan edits (R8)

struct ExerciseOption: Decodable, Identifiable, Equatable {
    let id: String
    let display: String
    let pattern: String?
}

struct ExerciseCatalogueResponse: Decodable {
    let exercises: [ExerciseOption]
}

struct PlanSwapRequest: Encodable, Equatable {
    let exerciseId: String
    let expectedExerciseId: String
}

struct PlanRemoveRequest: Encodable, Equatable {
    let expectedExerciseId: String
}

struct PlanSetsRequest: Encodable, Equatable {
    let delta: Int
    let expectedExerciseId: String
}

struct PlanAddRequest: Encodable, Equatable {
    let exerciseId: String
}

struct PlanItemChoice: Identifiable {
    let index: Int
    let identity: Int
    let item: PrescriptionItem

    var id: Int { index }

    var label: String {
        var parts = ["Item \(index + 1)"]
        if let sets = item.sets { parts.append("\(sets) sets") }
        parts.append(item.repsLabel)
        parts.append(item.loadLabel)
        parts.append(item.effortLabel)
        return parts.joined(separator: " · ")
    }
}

extension PrescriptionPlan {
    func choices(for exerciseId: String) -> [PlanItemChoice] {
        items.enumerated()
            .filter { $0.element.exerciseId == exerciseId }
            .map {
                PlanItemChoice(
                    index: $0.offset,
                    identity: $0.element.orderIndex ?? $0.offset,
                    item: $0.element
                )
            }
    }

    /// The array offset only when the exercise appears exactly once. A repeated exercise is
    /// ambiguous and must remain unattributed rather than silently using the first match.
    func uniquePlanItemIndex(for exerciseId: String) -> Int? {
        let matches = choices(for: exerciseId)
        return matches.count == 1 ? matches[0].index : nil
    }

    /// Resolve the set attribution: auto for a unique exercise, explicit only for a valid
    /// repeated-exercise selection, otherwise nil.
    func resolvedPlanItemIndex(for exerciseId: String, selected: Int?) -> Int? {
        let matches = choices(for: exerciseId)
        if matches.count == 1 { return matches[0].index }
        guard matches.count > 1, let selected,
              matches.contains(where: { $0.index == selected }) else {
            return nil
        }
        return selected
    }

    /// The stable identity sent to the server. The picker tag still uses the display position.
    func resolvedPlanItemIdentity(for exerciseId: String, selected: Int?) -> Int? {
        let matches = choices(for: exerciseId)
        if matches.count == 1 { return matches[0].identity }
        guard matches.count > 1, let selected,
              let choice = matches.first(where: { $0.index == selected }) else {
            return nil
        }
        return choice.identity
    }
}
