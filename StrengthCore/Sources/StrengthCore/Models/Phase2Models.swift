import Foundation

// MARK: - JSON helpers

/// A small JSON value used for server conflict details. The server only sends JSON here.
public enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
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

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - Prescription

public struct PrescriptionPlan: Codable {
    public let forDate: String?
    public let sessionType: String?
    public let sessionLabel: String?
    public let items: [PrescriptionItem]
    public let warnings: [String]?
    public let issues: [String]?

    public init(
        forDate: String?,
        sessionType: String?,
        sessionLabel: String?,
        items: [PrescriptionItem],
        warnings: [String]?,
        issues: [String]?
    ) {
        self.forDate = forDate
        self.sessionType = sessionType
        self.sessionLabel = sessionLabel
        self.items = items
        self.warnings = warnings
        self.issues = issues
    }
}

public struct WarmupSet: Codable, Equatable, Identifiable {
    public let percent: Double
    public let reps: Int
    public let loadKg: Double

    public init(percent: Double, reps: Int, loadKg: Double) {
        self.percent = percent
        self.reps = reps
        self.loadKg = loadKg
    }

    public var id: String { "\(percent)-\(reps)-\(loadKg)" }

    public var loadLabel: String {
        loadKg > 0 ? String(format: "%.1f kg", loadKg) : "bodyweight"
    }
}

public struct PrescriptionItem: Codable, Identifiable {
    public let orderIndex: Int?
    public let exerciseId: String?
    public let sets: Int?
    public let repsLow: Int?
    public let repsHigh: Int?
    public let loadKg: Double?
    public let loadBasis: String?
    public let rirTarget: Int?
    public let effortModel: String?
    public let refs: [String]?
    public let restS: Int?
    public let essential: Bool?
    public let warmup: [WarmupSet]?

    public init(
        orderIndex: Int?,
        exerciseId: String?,
        sets: Int?,
        repsLow: Int?,
        repsHigh: Int?,
        loadKg: Double?,
        loadBasis: String?,
        rirTarget: Int?,
        effortModel: String?,
        refs: [String]?,
        restS: Int?,
        essential: Bool?,
        warmup: [WarmupSet]? = nil
    ) {
        self.orderIndex = orderIndex
        self.exerciseId = exerciseId
        self.sets = sets
        self.repsLow = repsLow
        self.repsHigh = repsHigh
        self.loadKg = loadKg
        self.loadBasis = loadBasis
        self.rirTarget = rirTarget
        self.effortModel = effortModel
        self.refs = refs
        self.restS = restS
        self.essential = essential
        self.warmup = warmup
    }

    public var id: String { "\(orderIndex ?? 0)-\(exerciseId ?? "")" }

    public var loadLabel: String {
        guard let loadKg, loadKg > 0 else { return "bodyweight" }
        return String(format: "%.1f kg", loadKg)
    }

    public var repsLabel: String {
        switch (repsLow, repsHigh) {
        case let (low?, high?) where low == high: return "\(low)"
        case let (low?, high?): return "\(low)-\(high)"
        case let (low?, nil): return "\(low)+"
        default: return "—"
        }
    }

    public var effortLabel: String {
        if effortModel == "quality" { return "quality" }
        guard let rirTarget else { return "—" }
        return "RIR \(rirTarget)"
    }
}

// MARK: - Plan request (R7)

/// Workout settings sent with a request. The phone chooses an input; the server owns the plan.
public struct PlanSettings: Codable, Equatable {
    public var sessionType: String = "auto"
    public var minimumSession: Bool = false
    public var minimumTargetMinutes: Int?
    /// nil lets the server/resolver decide; true asks for top set/back-off; false asks for
    /// straight sets. The server still owns eligibility and every load/repetition decision.
    public var topSet: Bool? = nil

    public init(
        sessionType: String = "auto",
        minimumSession: Bool = false,
        minimumTargetMinutes: Int? = nil,
        topSet: Bool? = nil
    ) {
        self.sessionType = sessionType
        self.minimumSession = minimumSession
        self.minimumTargetMinutes = minimumTargetMinutes
        self.topSet = topSet
    }
}

/// The 202 acknowledgement: the request exists, the plan does not yet.
public struct PlanRequestAck: Decodable {
    public let issuedPlanId: String
    public let status: String
    public let forDate: String
    public let requestExpiresAt: String
    public let planExpiresAt: String?
    public let retryAfterMs: Int?
    public let settings: PlanSettings?
}

public struct PlanErrorBody: Decodable, Equatable {
    public let code: String
    public let message: String
}

/// The authoritative read: status is queued, building, ready, error or none.
public struct PlansStateResponse: Decodable {
    public let status: String
    public let issuedPlanId: String?
    public let forDate: String?
    public let elapsedSeconds: Int?
    public let requestExpiresAt: String?
    public let planExpiresAt: String?
    public let retryAfterMs: Int?
    public let settings: PlanSettings?
    public let executionTarget: String?
    public let sessionType: String?
    public let plan: PrescriptionPlan?
    public let readiness: ReadinessScore?
    public let warnings: [String]?
    public let error: PlanErrorBody?

    public static let none = PlansStateResponse(
        status: "none", issuedPlanId: nil, forDate: nil, elapsedSeconds: nil,
        requestExpiresAt: nil, planExpiresAt: nil, retryAfterMs: nil, settings: nil,
        executionTarget: nil, sessionType: nil, plan: nil, readiness: nil, warnings: nil,
        error: nil
    )

    /// A ready state is the only one that can be previewed and started.
    public var issuedPlan: IssuedPlanResponse? {
        guard status == "ready", let plan else { return nil }
        return IssuedPlanResponse(
            issuedPlanId: issuedPlanId ?? "",
            forDate: forDate ?? "",
            sessionType: sessionType ?? plan.sessionType ?? "",
            expiresAt: planExpiresAt ?? "",
            plan: plan,
            readiness: readiness,
            warnings: warnings ?? [],
            executionTarget: executionTarget
        )
    }
}

/// The preview the owner starts. R7: an unstarted plan is a preview, not a prescription.
public struct IssuedPlanResponse: Identifiable {
    public let issuedPlanId: String
    public let forDate: String
    public let sessionType: String
    public let expiresAt: String
    public let plan: PrescriptionPlan
    public let readiness: ReadinessScore?
    public let warnings: [String]
    public let executionTarget: String?

    public var id: String { issuedPlanId }
}

/// Permissive envelope for a journalled prescription response: a Phase 2 receipt may return the
/// old synchronous body, so only the shared identifier is read here.
public struct PlanAckEnvelope: Decodable {
    public let issuedPlanId: String?
    public let status: String?
}

/// Progress of an in-flight request, shown while the dispatcher builds.
public struct PlanProgress: Equatable {
    public var issuedPlanId: String
    public var status: String
    public var elapsedSeconds: Int
    public var settings: PlanSettings

    public init(issuedPlanId: String, status: String, elapsedSeconds: Int, settings: PlanSettings) {
        self.issuedPlanId = issuedPlanId
        self.status = status
        self.elapsedSeconds = elapsedSeconds
        self.settings = settings
    }
}

// MARK: - Workout

public struct WorkoutDetail: Codable, Identifiable {
    public let workoutId: String
    public let prescriptionId: String?
    public let forDate: String?
    public let sessionType: String?
    public let status: String
    public let plan: PrescriptionPlan?
    public let sets: [WorkoutSet]?
    public let forms: [WorkoutForm]?
    public let elapsedSeconds: Int?
    public let sessionRpe: Double?
    public let startedAt: String?
    /// Who owns this session. Missing means ownership cannot be confirmed, which is never
    /// permission to write.
    public let ownerDeviceId: String?
    /// The session's plan revision, as returned by the server on reads and plan edits.
    public let planRevision: Int?
    /// Last recorded activity, for a descriptive idle warning.
    public let lastActivityAt: String?

    public init(
        workoutId: String,
        prescriptionId: String?,
        forDate: String?,
        sessionType: String?,
        status: String,
        plan: PrescriptionPlan?,
        sets: [WorkoutSet]?,
        forms: [WorkoutForm]?,
        elapsedSeconds: Int?,
        sessionRpe: Double?,
        startedAt: String?,
        ownerDeviceId: String? = nil,
        planRevision: Int? = nil,
        lastActivityAt: String? = nil
    ) {
        self.workoutId = workoutId
        self.prescriptionId = prescriptionId
        self.forDate = forDate
        self.sessionType = sessionType
        self.status = status
        self.plan = plan
        self.sets = sets
        self.forms = forms
        self.elapsedSeconds = elapsedSeconds
        self.sessionRpe = sessionRpe
        self.startedAt = startedAt
        self.ownerDeviceId = ownerDeviceId
        self.planRevision = planRevision
        self.lastActivityAt = lastActivityAt
    }

    public var id: String { workoutId }

    /// The API returns the latest rating per exercise; use it to distinguish an initial rating
    /// from a correction without inventing a second local history.
    public func formRating(for exerciseId: String) -> WorkoutForm? {
        forms?.first { $0.exerciseId == exerciseId }
    }

    public func replacing(sets: [WorkoutSet]? = nil, forms: [WorkoutForm]? = nil) -> WorkoutDetail {
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

public struct WorkoutSet: Codable, Identifiable {
    public let setId: Int?
    public let exerciseId: String
    public let setIndex: Int?
    public let planItemIndex: Int?
    public let loadKg: Double?
    public let reps: Int?
    public let rir: Int?
    public let velocity: Double?
    public let source: String?
    public let repsDetail: WorkoutRepDetail?
    public let repSummary: WorkoutRepSummary?

    public init(
        setId: Int?,
        exerciseId: String,
        setIndex: Int?,
        planItemIndex: Int?,
        loadKg: Double?,
        reps: Int?,
        rir: Int?,
        velocity: Double?,
        source: String?,
        repsDetail: WorkoutRepDetail?,
        repSummary: WorkoutRepSummary?
    ) {
        self.setId = setId
        self.exerciseId = exerciseId
        self.setIndex = setIndex
        self.planItemIndex = planItemIndex
        self.loadKg = loadKg
        self.reps = reps
        self.rir = rir
        self.velocity = velocity
        self.source = source
        self.repsDetail = repsDetail
        self.repSummary = repSummary
    }

    public var id: String { "\(setId ?? 0)-\(exerciseId)-\(setIndex ?? 0)" }

    public var isPendingLocal: Bool { (setId ?? 0) < 0 }

    public var loadLabel: String {
        guard let loadKg, loadKg > 0 else { return "bodyweight" }
        return String(format: "%.1f kg", loadKg)
    }

    public var velocityLabel: String? {
        guard let velocity, velocity > 0 else { return nil }
        return String(format: "%.2f m/s", velocity)
    }

    public var summary: String {
        var parts = ["\(loadLabel) × \(reps ?? 0)"]
        if let rir { parts.append("RIR \(rir)") }
        if let velocityLabel { parts.append(velocityLabel) }
        return parts.joined(separator: " · ")
    }
}

public struct WorkoutRep: Codable, Identifiable {
    public let repIndex: Int
    public let velocityMps: Double

    public var id: Int { repIndex }
}

public struct WorkoutRepDetail: Codable {
    public let reps: [WorkoutRep]
    public let source: String?
    public let batchId: String?
}

public struct WorkoutRepSummary: Codable {
    public let count: Int
    public let first: Double
    public let last: Double
    public let mean: Double
    public let min: Double
    public let max: Double
    public let lossAbs: Double
    public let lossPct: Double?
}

public struct WorkoutForm: Codable, Identifiable {
    public let formId: Int?
    public let workoutId: String?
    public let exerciseId: String
    public let rating: Int
    public let note: String?

    public init(formId: Int?, workoutId: String?, exerciseId: String, rating: Int, note: String?) {
        self.formId = formId
        self.workoutId = workoutId
        self.exerciseId = exerciseId
        self.rating = rating
        self.note = note
    }

    public var id: String { "\(formId ?? 0)-\(workoutId ?? "")-\(exerciseId)" }
}

// MARK: - Progress

public struct ProgressResponse: Decodable {
    public let onDate: String
    public let coverage: ProgressCoverage
    public let performance: ProgressPerformance
    public let volume: [ProgressVolume]
    public let back: ProgressBack
    public let attendance: ProgressAttendance
    public let note: String?
}

public struct ProgressCoverage: Decodable {
    public let sessions: Int
    public let withSrpe: Int
    public let pct: Double
}

public struct ProgressPerformance: Decodable {
    public let points: [ProgressPoint]
    public let latest: ProgressPoint?
    public let medianRatio: Double?
    public let n: Int
}

public struct ProgressPoint: Decodable, Identifiable {
    public let date: String
    public let ratio: Double
    public let lifts: Int

    public var id: String { date }
}

public struct ProgressVolume: Decodable, Identifiable {
    public let pattern: String
    public let average: Double
    public let status: String
    // Untargeted patterns have no MRV landmark; the server sends null.
    public let mrv: Double?

    public var id: String { pattern }
}

public struct ProgressBack: Decodable {
    public let level: Int?
    public let date: String?
}

public struct ProgressAttendance: Decodable {
    public let weeks: Int
    public let from: String
    public let to: String
    public let completed: Int
    public let target: Int?
    public let pct: Double?
    public let note: String?
}


public enum RepVelocityParseError: LocalizedError, Equatable {
    case invalidNumber(String)
    case tooMany(reps: Int, provided: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidNumber(let token):
            return "Per-rep velocity '\(token)' must be a positive number."
        case .tooMany(let reps, let provided):
            return "Enter at most \(reps) per-rep velocities (\(provided) provided)."
        }
    }
}

public enum RepVelocityParser {
    /// Parse comma/space-separated m/s values for reps 1..n. Blank input means no detail.
    public static func parse(_ text: String, reps: Int) throws -> [RepVelocity]? {
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

public struct ReadinessWriteRequest: Encodable, Equatable {
    public let values: [String: Double]
    public let note: String?

    public init(values: [String: Double], note: String?) {
        self.values = values
        self.note = note
    }
}

public enum PrescriptionExecutionTarget: String, Codable, CaseIterable, Hashable, Sendable {
    case phone
    case watch

    public var label: String {
        switch self {
        case .phone: return "iPhone"
        case .watch: return "Apple Watch"
        }
    }
}

public struct IssuePrescriptionRequest: Encodable {
    public let readinessAck: Bool
    public let confirmations: [String: Bool]?
    public let settings: PlanSettings?
    public let executionTarget: PrescriptionExecutionTarget

    public init(
        readinessAck: Bool,
        confirmations: [String: Bool]?,
        settings: PlanSettings?,
        executionTarget: PrescriptionExecutionTarget = .phone
    ) {
        self.readinessAck = readinessAck
        self.confirmations = confirmations
        self.settings = settings
        self.executionTarget = executionTarget
    }
}

public struct StartWorkoutRequest: Encodable {
    public let issuedPlanId: String

    public init(issuedPlanId: String) {
        self.issuedPlanId = issuedPlanId
    }
}

public struct RepVelocity: Codable, Equatable, Identifiable {
    public let repIndex: Int
    public let velocityMps: Double

    public init(repIndex: Int, velocityMps: Double) {
        self.repIndex = repIndex
        self.velocityMps = velocityMps
    }

    public var id: Int { repIndex }
}

public struct AddSetRequest: Codable, Equatable {
    public let exerciseId: String
    public let loadKg: Double?
    public let reps: Int
    public let rir: Int?
    public let velocityMps: Double?
    public let setIndex: Int?
    public let planItemIndex: Int?
    public let repVelocities: [RepVelocity]?
    public let performedAt: String?

    public init(
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

public struct FormRatingRequest: Codable, Equatable {
    public let exerciseId: String
    public let rating: Int
    public let note: String?

    public init(exerciseId: String, rating: Int, note: String?) {
        self.exerciseId = exerciseId
        self.rating = rating
        self.note = note
    }
}

public struct RemoveSetRequest: Encodable, Equatable {
    public let setId: Int

    public init(setId: Int) {
        self.setId = setId
    }
}

public struct CompleteWorkoutRequest: Codable, Equatable {
    public let sessionRpe: Double?
    public let notRecorded: Bool
    public let durationMin: Double?
    public let notes: String?
    public let endedAt: String?
    public let productivity: Int?

    public init(
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

public struct EmptyRequest: Encodable {
    public init() {}
}

// MARK: - Exercise catalogue and plan edits (R8)

public struct ExerciseOption: Codable, Identifiable, Equatable {
    public let id: String
    public let display: String
    public let pattern: String?

    public init(id: String, display: String, pattern: String?) {
        self.id = id
        self.display = display
        self.pattern = pattern
    }
}

public struct ExerciseCatalogueResponse: Decodable {
    public let exercises: [ExerciseOption]
}

public struct PlanSwapRequest: Encodable, Equatable {
    public let exerciseId: String
    public let expectedExerciseId: String

    public init(exerciseId: String, expectedExerciseId: String) {
        self.exerciseId = exerciseId
        self.expectedExerciseId = expectedExerciseId
    }
}

public struct PlanRemoveRequest: Encodable, Equatable {
    public let expectedExerciseId: String

    public init(expectedExerciseId: String) {
        self.expectedExerciseId = expectedExerciseId
    }
}

public struct PlanSetsRequest: Encodable, Equatable {
    public let delta: Int
    public let expectedExerciseId: String

    public init(delta: Int, expectedExerciseId: String) {
        self.delta = delta
        self.expectedExerciseId = expectedExerciseId
    }
}

public struct PlanAddRequest: Encodable, Equatable {
    public let exerciseId: String

    public init(exerciseId: String) {
        self.exerciseId = exerciseId
    }
}

public struct PlanItemChoice: Identifiable {
    public let index: Int
    public let identity: Int
    public let item: PrescriptionItem

    public var id: Int { index }

    public var label: String {
        var parts = ["Item \(index + 1)"]
        if let sets = item.sets { parts.append("\(sets) sets") }
        parts.append(item.repsLabel)
        parts.append(item.loadLabel)
        parts.append(item.effortLabel)
        return parts.joined(separator: " · ")
    }
}

extension PrescriptionPlan {
    public func choices(for exerciseId: String) -> [PlanItemChoice] {
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
    public func uniquePlanItemIndex(for exerciseId: String) -> Int? {
        let matches = choices(for: exerciseId)
        return matches.count == 1 ? matches[0].index : nil
    }

    /// Resolve the set attribution: auto for a unique exercise, explicit only for a valid
    /// repeated-exercise selection, otherwise nil.
    public func resolvedPlanItemIndex(for exerciseId: String, selected: Int?) -> Int? {
        let matches = choices(for: exerciseId)
        if matches.count == 1 { return matches[0].index }
        guard matches.count > 1, let selected,
              matches.contains(where: { $0.index == selected }) else {
            return nil
        }
        return selected
    }

    /// The stable identity sent to the server. The picker tag still uses the display position.
    public func resolvedPlanItemIdentity(for exerciseId: String, selected: Int?) -> Int? {
        let matches = choices(for: exerciseId)
        if matches.count == 1 { return matches[0].identity }
        guard matches.count > 1, let selected,
              let choice = matches.first(where: { $0.index == selected }) else {
            return nil
        }
        return choice.identity
    }
}
