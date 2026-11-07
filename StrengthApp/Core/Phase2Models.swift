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

struct PrescriptionPlan: Decodable {
    let forDate: String?
    let sessionType: String?
    let sessionLabel: String?
    let items: [PrescriptionItem]
    let warnings: [String]?
    let issues: [String]?
}

struct PrescriptionItem: Decodable, Identifiable {
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

struct IssuedPlanResponse: Decodable, Identifiable {
    let issuedPlanId: String
    let prescriptionId: String
    let forDate: String
    let sessionType: String
    let expiresAt: String
    let plan: PrescriptionPlan
    let readiness: ReadinessScore?
    let warnings: [String]?

    var id: String { issuedPlanId }
}

// MARK: - Workout

struct WorkoutDetail: Decodable, Identifiable {
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
}

struct WorkoutSet: Decodable, Identifiable {
    let setId: Int?
    let exerciseId: String
    let setIndex: Int?
    let loadKg: Double?
    let reps: Int?
    let rir: Int?
    let velocity: Double?
    let source: String?

    var id: String { "\(setId ?? 0)-\(exerciseId)-\(setIndex ?? 0)" }

    var loadLabel: String {
        guard let loadKg, loadKg > 0 else { return "bodyweight" }
        return String(format: "%.1f kg", loadKg)
    }

    var velocityLabel: String? {
        guard let velocity, velocity > 0 else { return nil }
        return String(format: "%.2f m/s", velocity)
    }
}

struct WorkoutForm: Decodable, Identifiable {
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
    let mrv: Double

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

// MARK: - Requests

struct ReadinessWriteRequest: Encodable, Equatable {
    let values: [String: Double]
    let note: String?
}

struct IssuePrescriptionRequest: Encodable {
    let readinessAck: Bool
    let confirmations: [String: Bool]?
}

struct StartWorkoutRequest: Encodable {
    let issuedPlanId: String
}

struct AddSetRequest: Encodable, Equatable {
    let exerciseId: String
    let loadKg: Double?
    let reps: Int
    let rir: Int?
    let velocityMps: Double?
    let setIndex: Int?
    let planItemIndex: Int?
}

struct FormRatingRequest: Encodable, Equatable {
    let exerciseId: String
    let rating: Int
    let note: String?
}

struct CompleteWorkoutRequest: Encodable, Equatable {
    let sessionRpe: Double?
    let notRecorded: Bool
    let durationMin: Double?
    let notes: String?
}

struct EmptyRequest: Encodable {}
struct PlanItemChoice: Identifiable {
    let index: Int
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
            .map { PlanItemChoice(index: $0.offset, item: $0.element) }
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
}
