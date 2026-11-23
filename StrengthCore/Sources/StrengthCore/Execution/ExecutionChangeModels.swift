import Foundation

/// One mid-session execution change pushed by the phone: a substitution for a frozen plan slot,
/// or extra work after an item. The event is a live view hint and a prefill source; the performed
/// set is the durable record (DEC-RESOLVER-23).
public struct ExecutionChange: Codable, Sendable, Equatable, Identifiable {
    public let eventId: Int?
    public let kind: String?
    public let planItemIndex: Int?
    public let afterItemIndex: Int?
    public let exerciseId: String?
    public let repsLow: Int?
    public let repsHigh: Int?
    public let rirTarget: Int?
    public let prefillLoadKg: Double?
    public let prefillReason: String?
    /// The server's verification of the number the athlete saw. A false value is a log
    /// diagnostic, never a reason to replace the displayed load.
    public let prefillVerified: Bool?
    public let prefillExpectedLoadKg: Double?
    public let prefillMismatchReason: String?
    /// Which path produced the replacement: "catalogue" or "server".
    public let resolvedBy: String?
    /// The replacement's own set count and per-group prescription.
    public let sets: Int?
    public let setGroups: [SetGroup]?
    /// Top-set eligibility is not inherited by a substitute; the server states it.
    public let topSet: TopSetStatus?
    /// Catalogue-path velocity target, when the lift has a trustworthy calibration.
    public let vbtTarget: ExecutionVBT?
    /// Server-path velocity target.
    public let vbt: ExecutionVBT?
    public let createdAt: String?

    public init(
        eventId: Int? = nil,
        kind: String? = nil,
        planItemIndex: Int? = nil,
        afterItemIndex: Int? = nil,
        exerciseId: String? = nil,
        repsLow: Int? = nil,
        repsHigh: Int? = nil,
        rirTarget: Int? = nil,
        prefillLoadKg: Double? = nil,
        prefillReason: String? = nil,
        prefillVerified: Bool? = nil,
        prefillExpectedLoadKg: Double? = nil,
        prefillMismatchReason: String? = nil,
        resolvedBy: String? = nil,
        sets: Int? = nil,
        setGroups: [SetGroup]? = nil,
        topSet: TopSetStatus? = nil,
        vbtTarget: ExecutionVBT? = nil,
        vbt: ExecutionVBT? = nil,
        createdAt: String? = nil
    ) {
        self.eventId = eventId
        self.kind = kind
        self.planItemIndex = planItemIndex
        self.afterItemIndex = afterItemIndex
        self.exerciseId = exerciseId
        self.repsLow = repsLow
        self.repsHigh = repsHigh
        self.rirTarget = rirTarget
        self.prefillLoadKg = prefillLoadKg
        self.prefillReason = prefillReason
        self.prefillVerified = prefillVerified
        self.prefillExpectedLoadKg = prefillExpectedLoadKg
        self.prefillMismatchReason = prefillMismatchReason
        self.resolvedBy = resolvedBy
        self.sets = sets
        self.setGroups = setGroups
        self.topSet = topSet
        self.vbtTarget = vbtTarget
        self.vbt = vbt
        self.createdAt = createdAt
    }

    public var id: String {
        "\(eventId ?? 0)-\(kind ?? "")-\(planItemIndex ?? afterItemIndex ?? -1)"
    }

    public var isSubstitution: Bool { kind == "substitution" }
    public var isAddition: Bool { kind == "addition" }

    public var repsLabel: String {
        switch (repsLow, repsHigh) {
        case let (low?, high?) where low == high: return "\(low)"
        case let (low?, high?): return "\(low)-\(high)"
        case let (low?, nil): return "\(low)+"
        default: return "—"
        }
    }

    public var loadLabel: String {
        guard let prefillLoadKg, prefillLoadKg > 0 else { return "load not prefilled" }
        return String(format: "%.1f kg", prefillLoadKg)
    }

    public var velocityTarget: ExecutionVBT? { vbtTarget ?? vbt }

    public var velocityTargetLabel: String? {
        guard let target = velocityTarget?.targetMps, target > 0 else { return nil }
        return String(format: "%.2f m/s", target)
    }

    public var topSetNote: String? {
        guard topSet?.status == "not_applicable",
              topSet?.reasonCode == "substituted" else { return nil }
        return "Top set not applicable · substituted"
    }
}

/// The velocity target shape used by both the catalogue (`vbt_target`) and the server solve
/// (`vbt`). Values are shown as shipped; the client never reconstructs one.
public struct ExecutionVBT: Codable, Equatable, Sendable {
    public let targetMps: Double?
    public let lowMps: Double?
    public let highMps: Double?
    public let repCount: Int?
    public let rirLow: Int?
    public let rirHigh: Int?
    public let scope: String?
    public let nSets: Int?
    public let nSessions: Int?
    public let calibrationId: String?
}

/// The server's current execution view: the latest substitution per plan slot and every
/// addition, ordered by the watermark. A watch applies a payload only when the watermark is at
/// least as new as its own (contract section 10, DEC-RESOLVER-23).
public struct ExecutionView: Codable, Sendable, Equatable {
    public let workoutId: String?
    public let watermark: Int
    public let substitutions: [ExecutionChange]
    public let additions: [ExecutionChange]

    public init(
        workoutId: String? = nil,
        watermark: Int = 0,
        substitutions: [ExecutionChange] = [],
        additions: [ExecutionChange] = []
    ) {
        self.workoutId = workoutId
        self.watermark = watermark
        self.substitutions = substitutions
        self.additions = additions
    }

    public static let empty = ExecutionView()

    /// One display row per plan item, with its substitution applied, plus additions after their
    /// anchor. Order is the plan order; an addition whose anchor is gone stays at the end.
    public func rows(plan: PrescriptionPlan?) -> [ExecutionRow] {
        let items = plan?.items ?? []
        var substitutionBySlot: [Int: ExecutionChange] = [:]
        for change in substitutions {
            if let slot = change.planItemIndex {
                substitutionBySlot[slot] = change
            }
        }
        var rows: [ExecutionRow] = []
        var consumed: Set<String> = []
        for (position, item) in items.enumerated() {
            let identity = item.orderIndex ?? position
            let plannedExercise = item.exerciseId ?? ""
            if let change = substitutionBySlot[identity] {
                rows.append(ExecutionRow(
                    id: "item-\(identity)",
                    kind: .substituted,
                    planItemIndex: identity,
                    afterItemIndex: nil,
                    exerciseId: change.exerciseId ?? plannedExercise,
                    plannedExerciseId: plannedExercise,
                    sets: change.sets ?? item.sets,
                    loadKg: change.prefillLoadKg,
                    repsLow: change.repsLow ?? item.repsLow,
                    repsHigh: change.repsHigh ?? item.repsHigh,
                    rirTarget: change.rirTarget,
                    groups: change.setGroups ?? [],
                    change: change
                ))
            } else {
                rows.append(ExecutionRow(
                    id: "item-\(identity)",
                    kind: .planned,
                    planItemIndex: identity,
                    afterItemIndex: nil,
                    exerciseId: plannedExercise,
                    plannedExerciseId: nil,
                    sets: item.sets,
                    loadKg: item.loadKg,
                    repsLow: item.repsLow,
                    repsHigh: item.repsHigh,
                    rirTarget: item.rirTarget,
                    groups: item.setGroups ?? [],
                    change: nil
                ))
            }
            for addition in additions where addition.afterItemIndex == identity {
                consumed.insert(addition.id)
                rows.append(ExecutionRow(
                    id: "addition-\(addition.id)",
                    kind: .added,
                    planItemIndex: nil,
                    afterItemIndex: identity,
                    exerciseId: addition.exerciseId ?? "",
                    plannedExerciseId: nil,
                    sets: addition.sets,
                    loadKg: addition.prefillLoadKg,
                    repsLow: addition.repsLow,
                    repsHigh: addition.repsHigh,
                    rirTarget: addition.rirTarget,
                    groups: addition.setGroups ?? [],
                    change: addition
                ))
            }
        }
        for addition in additions where !consumed.contains(addition.id) {
            rows.append(ExecutionRow(
                id: "addition-\(addition.id)",
                kind: .added,
                planItemIndex: nil,
                afterItemIndex: nil,
                exerciseId: addition.exerciseId ?? "",
                plannedExerciseId: nil,
                sets: addition.sets,
                loadKg: addition.prefillLoadKg,
                repsLow: addition.repsLow,
                repsHigh: addition.repsHigh,
                rirTarget: addition.rirTarget,
                groups: addition.setGroups ?? [],
                change: addition
            ))
        }
        return rows
    }
}

/// One row a client renders and logs against. A planned row keeps its plan slot and groups; a
/// substituted row keeps the slot for attribution and keeps the substitute as the performed
/// exercise; an added row has no plan slot and counts as extra work.
public struct ExecutionRow: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case planned
        case substituted
        case added
    }

    public let id: String
    public let kind: Kind
    public let planItemIndex: Int?
    public let afterItemIndex: Int?
    public let exerciseId: String
    public let plannedExerciseId: String?
    public let sets: Int?
    public let loadKg: Double?
    public let repsLow: Int?
    public let repsHigh: Int?
    public let rirTarget: Int?
    public let groups: [SetGroup]
    public let change: ExecutionChange?

    public init(
        id: String,
        kind: Kind,
        planItemIndex: Int?,
        afterItemIndex: Int?,
        exerciseId: String,
        plannedExerciseId: String?,
        sets: Int?,
        loadKg: Double?,
        repsLow: Int?,
        repsHigh: Int?,
        rirTarget: Int?,
        groups: [SetGroup],
        change: ExecutionChange?
    ) {
        self.id = id
        self.kind = kind
        self.planItemIndex = planItemIndex
        self.afterItemIndex = afterItemIndex
        self.exerciseId = exerciseId
        self.plannedExerciseId = plannedExerciseId
        self.sets = sets
        self.loadKg = loadKg
        self.repsLow = repsLow
        self.repsHigh = repsHigh
        self.rirTarget = rirTarget
        self.groups = groups
        self.change = change
    }

    public var substitutesPlanItemIndex: Int? {
        kind == .substituted ? planItemIndex : nil
    }

    /// The next planned group for the nth logged set, by cumulative set count; the last group
    /// holds beyond the plan. Nil for straight sets and extra work.
    public func group(forLoggedCount logged: Int) -> SetGroup? {
        guard !groups.isEmpty else { return nil }
        let target = logged + 1
        var cumulative = 0
        for group in groups {
            cumulative += group.sets ?? 0
            if target <= cumulative { return group }
        }
        return groups.last
    }

    public var loadLabel: String {
        guard let loadKg else { return "load unknown" }
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
        guard let rirTarget else { return "—" }
        return "RIR \(rirTarget)"
    }

    /// The substitute's shipped or solved velocity target, shown as supplied.
    public var velocityTargetLabel: String? { change?.velocityTargetLabel }

    /// A substitute's top-set eligibility is not inherited from the planned lift.
    public var topSetNote: String? { change?.topSetNote }
}

/// The phone's authoring body. There is no legacy prefill flag: a value means the phone applied
/// the catalogue, a version with no value records a catalogue miss, and neither asks the server
/// to solve.
public struct ExecutionChangeRequest: Encodable, Equatable, Sendable {
    public let eventId: String
    public let change: String
    public let planItemIndex: Int?
    public let afterItemIndex: Int?
    public let exerciseId: String
    public let repsLow: Int?
    public let repsHigh: Int?
    public let rirTarget: Int?
    /// The client-applied load from the shipped catalogue, and the snapshot it came from.
    public let prefillLoadKg: Double?
    public let prefillCatalogueVersion: String?
    public let prefillAsOf: String?

    public init(
        eventId: String,
        change: String,
        planItemIndex: Int? = nil,
        afterItemIndex: Int? = nil,
        exerciseId: String,
        repsLow: Int? = nil,
        repsHigh: Int? = nil,
        rirTarget: Int? = nil,
        prefillLoadKg: Double? = nil,
        prefillCatalogueVersion: String? = nil,
        prefillAsOf: String? = nil
    ) {
        self.eventId = eventId
        self.change = change
        self.planItemIndex = planItemIndex
        self.afterItemIndex = afterItemIndex
        self.exerciseId = exerciseId
        self.repsLow = repsLow
        self.repsHigh = repsHigh
        self.rirTarget = rirTarget
        self.prefillLoadKg = prefillLoadKg
        self.prefillCatalogueVersion = prefillCatalogueVersion
        self.prefillAsOf = prefillAsOf
    }
}

public struct ExecutionChangeResponse: Decodable, Sendable {
    public let execution: ExecutionView
}

/// A GET execution payload carries the timing analytics plus this block; a client that only needs
/// the view decodes the block and ignores the rest.
public struct ExecutionViewResponse: Decodable, Sendable {
    public let execution: ExecutionView?
}
