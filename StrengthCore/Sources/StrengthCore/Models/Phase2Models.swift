import Foundation

// MARK: - JSON helpers

/// A small JSON value used for server conflict details. The server only sends JSON here.
public enum JSONValue: Codable, Equatable, Sendable {
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

/// The frozen top-set outcome from the plan. Status is applied, not_applicable, fallback or
/// unsatisfied; reason_code names the blocker and reason is the human text (DEC-RESOLVER-24).
public struct TopSetStatus: Codable, Equatable, Sendable {
    public let status: String?
    public let reasonCode: String?
    public let reason: String?
    public let topSetLoadKg: Double?
    public let topSetRir: Int?
    public let backoffLoadKg: Double?

    public init(
        status: String? = nil,
        reasonCode: String? = nil,
        reason: String? = nil,
        topSetLoadKg: Double? = nil,
        topSetRir: Int? = nil,
        backoffLoadKg: Double? = nil
    ) {
        self.status = status
        self.reasonCode = reasonCode
        self.reason = reason
        self.topSetLoadKg = topSetLoadKg
        self.topSetRir = topSetRir
        self.backoffLoadKg = backoffLoadKg
    }

    public var isApplied: Bool { status == "applied" }

    public var statusLabel: String {
        switch status {
        case "applied": return "Applied"
        case "not_applicable": return "Not applicable"
        case "fallback": return "Fell back to straight sets"
        case "unsatisfied": return "Required but unavailable"
        default: return status ?? "Unknown"
        }
    }
}

public struct PrescriptionPlan: Codable, Sendable {
    public let forDate: String?
    public let sessionType: String?
    public let sessionLabel: String?
    public let items: [PrescriptionItem]
    public let warnings: [String]?
    public let issues: [String]?
    /// Frozen top-set outcome; nil for plans issued before the tri-state.
    public let topSet: TopSetStatus?

    public init(
        forDate: String?,
        sessionType: String?,
        sessionLabel: String?,
        items: [PrescriptionItem],
        warnings: [String]?,
        issues: [String]?,
        topSet: TopSetStatus? = nil
    ) {
        self.forDate = forDate
        self.sessionType = sessionType
        self.sessionLabel = sessionLabel
        self.items = items
        self.warnings = warnings
        self.issues = issues
        self.topSet = topSet
    }
}

public struct WarmupSet: Codable, Equatable, Sendable, Identifiable {
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

/// One planned set group inside a prescription item. Order is the only identity: the server
/// sends group_index and no role, so the client renders the list in order (DEC-RESOLVER-18).
public struct SetGroup: Codable, Sendable, Equatable {
    public let groupIndex: Int?
    public let sets: Int?
    public let loadKg: Double?
    public let repsLow: Int?
    public let repsHigh: Int?
    public let rirTarget: Int?

    public init(
        groupIndex: Int? = nil,
        sets: Int? = nil,
        loadKg: Double? = nil,
        repsLow: Int? = nil,
        repsHigh: Int? = nil,
        rirTarget: Int? = nil
    ) {
        self.groupIndex = groupIndex
        self.sets = sets
        self.loadKg = loadKg
        self.repsLow = repsLow
        self.repsHigh = repsHigh
        self.rirTarget = rirTarget
    }

    public var repsLabel: String {
        switch (repsLow, repsHigh) {
        case let (low?, high?) where low == high: return String(low)
        case let (low?, high?): return String(low) + "-" + String(high)
        case let (low?, nil): return String(low) + "+"
        default: return "—"
        }
    }

    public var loadLabel: String {
        guard let loadKg, loadKg > 0 else { return "load unknown" }
        return String(format: "%.1f kg", loadKg)
    }

    /// One unlabelled display row: sets x reps @ load, RIR.
    public var rowLabel: String {
        var label = String(sets ?? 0) + " × " + repsLabel
        if let loadKg, loadKg > 0 { label += " @ " + String(format: "%.1f kg", loadKg) }
        if let rirTarget { label += " · RIR " + String(rirTarget) }
        return label
    }
}

public struct PrescriptionItem: Codable, Sendable, Identifiable {
    public let orderIndex: Int?
    public let exerciseId: String?
    public let sets: Int?
    public let repsLow: Int?
    public let repsHigh: Int?
    /// "seconds" for a time-based hold; absent/legacy plans mean repetitions.
    public let repsUnit: String?
    public let loadKg: Double?
    public let loadBasis: String?
    /// Present when the plan deliberately has no load for this item, e.g. a swap made during
    /// the workout. A nil load is not the same thing as a bodyweight load.
    public let unknownLoadReason: String?
    public let rirTarget: Int?
    public let effortModel: String?
    public let refs: [String]?
    public let restS: Int?
    public let essential: Bool?
    public let warmup: [WarmupSet]?
    /// Present only for lifts with a velocity calibration; nil means the plan asks for no
    /// bar speed, so the client must not offer the field.
    public let velocityTarget: Double?
    /// Ordered planned set groups; nil or empty is straight sets (DEC-RESOLVER-18).
    public let setGroups: [SetGroup]?

    public init(
        orderIndex: Int?,
        exerciseId: String?,
        sets: Int?,
        repsLow: Int?,
        repsHigh: Int?,
        repsUnit: String? = nil,
        loadKg: Double?,
        loadBasis: String?,
        unknownLoadReason: String? = nil,
        rirTarget: Int?,
        effortModel: String?,
        refs: [String]?,
        restS: Int?,
        essential: Bool?,
        warmup: [WarmupSet]? = nil,
        velocityTarget: Double? = nil,
        setGroups: [SetGroup]? = nil
    ) {
        self.orderIndex = orderIndex
        self.exerciseId = exerciseId
        self.sets = sets
        self.repsLow = repsLow
        self.repsHigh = repsHigh
        self.repsUnit = repsUnit
        self.loadKg = loadKg
        self.loadBasis = loadBasis
        self.unknownLoadReason = unknownLoadReason
        self.rirTarget = rirTarget
        self.effortModel = effortModel
        self.refs = refs
        self.restS = restS
        self.essential = essential
        self.warmup = warmup
        self.velocityTarget = velocityTarget
        self.setGroups = setGroups
    }

    public var id: String { "\(orderIndex ?? 0)-\(exerciseId ?? "")" }

    public var loadLabel: String {
        if loadBasis == "bodyweight" || loadBasis == "bodyweight_total" || loadKg == 0 {
            return "bodyweight"
        }
        guard let loadKg else { return "Load not set" }
        guard loadKg > 0 else { return "bodyweight" }
        return String(format: "%.1f kg", loadKg)
    }

    public var repsLabel: String {
        let suffix = repsUnit == "seconds" ? "s" : ""
        switch (repsLow, repsHigh) {
        case let (low?, high?) where low == high: return "\(low)\(suffix)"
        case let (low?, high?): return "\(low)-\(high)\(suffix)"
        case let (low?, nil): return "\(low)+\(suffix)"
        default: return "—"
        }
    }

    public var isTimeBased: Bool { repsUnit == "seconds" }

    public var effortLabel: String {
        if effortModel == "quality" { return "quality" }
        guard let rirTarget else { return "—" }
        return "RIR \(rirTarget)"
    }

    /// Display form of the server's prescribed bar-speed target. Nil when the plan asks for
    /// no target; the client never derives or adjusts one.
    public var velocityTargetLabel: String? {
        guard let velocityTarget, velocityTarget > 0 else { return nil }
        return String(format: "%.2f m/s", velocityTarget)
    }
}

// MARK: - Plan request (R7)

/// One request-time top-set choice. Nil follows the settings profile; the server still owns
/// eligibility, structure, loads and every training decision (DEC-RESOLVER-24).
public enum PrescriptionTopSetIntent: String, Codable, CaseIterable, Sendable {
    case off
    case preferred
    case required

    public var label: String {
        switch self {
        case .off: return "Straight sets"
        case .preferred: return "Prefer top set + back-off"
        case .required: return "Require top set + back-off"
        }
    }
}

/// Workout settings sent with a request. The phone chooses an input; the server owns the plan.
public struct PlanSettings: Codable, Equatable {
    public var sessionType: String = "auto"
    public var minimumSession: Bool = false
    public var minimumTargetMinutes: Int?
    /// nil follows the settings profile; otherwise this request overrides it.
    public var topSetIntent: PrescriptionTopSetIntent? = nil
    /// MOD-TECH-001: applies a user-declared technique throttle to main work when the server
    /// builds the plan. A per-session request, never stored state. Off is sent explicitly so the
    /// server can distinguish "not throttled" from an older client that omitted the field.
    public var techniqueThrottle: Bool = false

    public init(
        sessionType: String = "auto",
        minimumSession: Bool = false,
        minimumTargetMinutes: Int? = nil,
        topSetIntent: PrescriptionTopSetIntent? = nil,
        techniqueThrottle: Bool = false
    ) {
        self.sessionType = sessionType
        self.minimumSession = minimumSession
        self.minimumTargetMinutes = minimumTargetMinutes
        self.topSetIntent = topSetIntent
        self.techniqueThrottle = techniqueThrottle
    }

    private enum CodingKeys: String, CodingKey {
        case sessionType
        case minimumSession
        case minimumTargetMinutes
        case topSetIntent
        case techniqueThrottle
    }

    /// A response may carry only the fields that changed; every absent setting keeps its
    /// default rather than failing the whole plan read.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionType = try container.decodeIfPresent(String.self, forKey: .sessionType) ?? "auto"
        minimumSession = try container.decodeIfPresent(Bool.self, forKey: .minimumSession) ?? false
        minimumTargetMinutes = try container.decodeIfPresent(Int.self, forKey: .minimumTargetMinutes)
        topSetIntent = try container.decodeIfPresent(
            PrescriptionTopSetIntent.self, forKey: .topSetIntent
        )
        techniqueThrottle = try container.decodeIfPresent(
            Bool.self, forKey: .techniqueThrottle
        ) ?? false
    }
}

/// The 202 acknowledgement: the request exists, the plan does not yet.
public struct PlanRequestAck: Decodable {
    public let issuedPlanId: String
    /// The workout this plan will become, minted at issue so an offline start can name it.
    public let executionId: String?
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
    public let executionId: String?
    public let forDate: String?
    public let elapsedSeconds: Int?
    public let requestExpiresAt: String?
    public let planExpiresAt: String?
    public let retryAfterMs: Int?
    public let settings: PlanSettings?
    public let sessionType: String?
    public let plan: PrescriptionPlan?
    /// The server-built catalogue shipped with the plan; nil for a plan built before it existed.
    public let loadCatalogue: LoadCatalogue?
    public let readiness: ReadinessScore?
    public let warnings: [String]?
    public let error: PlanErrorBody?

    public static let none = PlansStateResponse(
        status: "none", issuedPlanId: nil, executionId: nil, forDate: nil,
        elapsedSeconds: nil, requestExpiresAt: nil, planExpiresAt: nil, retryAfterMs: nil,
        settings: nil, sessionType: nil, plan: nil,
        loadCatalogue: nil, readiness: nil, warnings: nil, error: nil
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
            executionID: executionId,
            loadCatalogue: loadCatalogue
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
    /// The plan's execution identity. It becomes the workout id when the plan is started.
    public let executionID: String?
    public let loadCatalogue: LoadCatalogue?

    public var id: String { issuedPlanId }

    /// MOD-TECH-001 is frozen into the plan at build time; the item rationale refs carry it.
    public var techniqueThrottledItems: [PrescriptionItem] {
        plan.items.filter { ($0.refs ?? []).contains("MOD-TECH-001") }
    }

    public var techniqueThrottleInForce: Bool {
        !techniqueThrottledItems.isEmpty
    }
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
    /// The frozen plan slot this set replaced; set only for an annotated substitution
    /// (DEC-RESOLVER-23). Nil for ordinary and extra work.
    public let substitutesPlanItemIndex: Int?
    public let originDeviceId: String?

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
        repSummary: WorkoutRepSummary?,
        substitutesPlanItemIndex: Int? = nil,
        originDeviceId: String? = nil
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
        self.substitutesPlanItemIndex = substitutesPlanItemIndex
        self.originDeviceId = originDeviceId
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

public struct IssuePrescriptionRequest: Encodable {
    public let readinessAck: Bool
    public let confirmations: [String: Bool]?
    public let settings: PlanSettings?

    public init(
        readinessAck: Bool,
        confirmations: [String: Bool]?,
        settings: PlanSettings?
    ) {
        self.readinessAck = readinessAck
        self.confirmations = confirmations
        self.settings = settings
    }
}

public struct StartWorkoutRequest: Codable, Equatable {
    public let issuedPlanId: String
    /// The plan's execution identity; it binds the workout id. Omitted by older clients.
    public let executionId: String?
    /// The athlete's recorded start, required when the start came from a cached plan.
    public let startedAt: String?

    public init(issuedPlanId: String, executionId: String? = nil, startedAt: String? = nil) {
        self.issuedPlanId = issuedPlanId
        self.executionId = executionId
        self.startedAt = startedAt
    }
}

public struct RepVelocity: Codable, Equatable, Sendable, Identifiable {
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
    public let substitutesPlanItemIndex: Int?
    public let repVelocities: [RepVelocity]?
    public let performedAt: String?
    /// The device that captured the set. The phone commits it; the server validates that the
    /// origin belongs to the same pairing.
    public let originDeviceId: String?

    public init(
        exerciseId: String,
        loadKg: Double?,
        reps: Int,
        rir: Int?,
        velocityMps: Double?,
        setIndex: Int?,
        planItemIndex: Int?,
        substitutesPlanItemIndex: Int? = nil,
        repVelocities: [RepVelocity]? = nil,
        performedAt: String? = nil,
        originDeviceId: String? = nil
    ) {
        self.exerciseId = exerciseId
        self.loadKg = loadKg
        self.reps = reps
        self.rir = rir
        self.velocityMps = velocityMps
        self.setIndex = setIndex
        self.planItemIndex = planItemIndex
        self.substitutesPlanItemIndex = substitutesPlanItemIndex
        self.repVelocities = repVelocities
        self.performedAt = performedAt
        self.originDeviceId = originDeviceId
    }

    public func withSetIndex(_ setIndex: Int) -> AddSetRequest {
        AddSetRequest(
            exerciseId: exerciseId,
            loadKg: loadKg,
            reps: reps,
            rir: rir,
            velocityMps: velocityMps,
            setIndex: setIndex,
            planItemIndex: planItemIndex,
            substitutesPlanItemIndex: substitutesPlanItemIndex,
            repVelocities: repVelocities,
            performedAt: performedAt,
            originDeviceId: originDeviceId
        )
    }

    public func withOriginDeviceId(_ deviceId: String?) -> AddSetRequest {
        AddSetRequest(
            exerciseId: exerciseId,
            loadKg: loadKg,
            reps: reps,
            rir: rir,
            velocityMps: velocityMps,
            setIndex: setIndex,
            planItemIndex: planItemIndex,
            substitutesPlanItemIndex: substitutesPlanItemIndex,
            repVelocities: repVelocities,
            performedAt: performedAt,
            originDeviceId: deviceId
        )
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

public struct RemoveSetRequest: Codable, Equatable {
    public let setId: Int

    public init(setId: Int) {
        self.setId = setId
    }
}

/// One correction to a performed set. The server appends a correction event; the set keeps its
/// `set_id` and `set_index`, which the merge map and telemetry links depend on.
public struct UpdateSetRequest: Codable, Equatable {
    public let setId: Int
    public let loadKg: Double?
    public let reps: Int?
    public let rir: Int?
    public let velocityMps: Double?

    public init(
        setId: Int,
        loadKg: Double? = nil,
        reps: Int? = nil,
        rir: Int? = nil,
        velocityMps: Double? = nil
    ) {
        self.setId = setId
        self.loadKg = loadKg
        self.reps = reps
        self.rir = rir
        self.velocityMps = velocityMps
    }
}

public struct CompleteWorkoutRequest: Codable, Equatable {
    public let sessionRpe: Double?
    public let notRecorded: Bool
    public let durationMin: Double?
    public let notes: String?
    public let endedAt: String?
    public let productivity: Int?
    /// Devices whose events had not arrived when this device finished. A non-empty list opens
    /// the server's late-reconciliation window.
    public let pendingDevices: [String]?

    public init(
        sessionRpe: Double?,
        notRecorded: Bool,
        durationMin: Double?,
        notes: String?,
        endedAt: String? = nil,
        productivity: Int? = nil,
        pendingDevices: [String]? = nil
    ) {
        self.sessionRpe = sessionRpe
        self.notRecorded = notRecorded
        self.durationMin = durationMin
        self.notes = notes
        self.endedAt = endedAt
        self.productivity = productivity
        self.pendingDevices = pendingDevices
    }

    public func withPendingDevices(_ devices: [String]?) -> CompleteWorkoutRequest {
        CompleteWorkoutRequest(
            sessionRpe: sessionRpe,
            notRecorded: notRecorded,
            durationMin: durationMin,
            notes: notes,
            endedAt: endedAt,
            productivity: productivity,
            pendingDevices: devices
        )
    }
}

public struct ReconciliationDeviceRequest: Encodable, Equatable {
    public let deviceId: String

    public init(deviceId: String) {
        self.deviceId = deviceId
    }
}

public struct WorkoutReconciliationResponse: Decodable, Equatable {
    public let reconciliation: WorkoutReconciliation
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
