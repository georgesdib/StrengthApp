import Foundation

/// The server-built load catalogue shipped with an issued plan (unified offline execution D9).
///
/// The catalogue is the training decision: each entry is already the resolver's own output. The
/// client applies only the deterministic tail documented in the plan:
///
///     power or bodyweight -> 0 / nil with a reason
///     essential slot      -> round_down(base / (1 + (reps + rir) / 30), increment)
///     accessory slot      -> round_down(accessory, increment)
///
/// Rounding is decimal arithmetic from the shipped number, never a binary floating-point
/// intermediate, so a value that lands exactly on an increment is not rounded to the step below.
public struct LoadCatalogue: Codable, Equatable, Sendable {
    public let catalogueVersion: String?
    public let asOf: String?
    public let exercises: [String: LoadCatalogueEntry]

    public init(
        catalogueVersion: String? = nil,
        asOf: String? = nil,
        exercises: [String: LoadCatalogueEntry] = [:]
    ) {
        self.catalogueVersion = catalogueVersion
        self.asOf = asOf
        self.exercises = exercises
    }

    public var version: String { catalogueVersion ?? "" }

    public func entry(for exerciseId: String) -> LoadCatalogueEntry? {
        exercises[exerciseId]
    }

    /// The client tail. A missing entry or base returns nil and the reason, never a made-up number.
    public func prefill(
        exerciseId: String,
        essential: Bool,
        reps: Int,
        rir: Int?
    ) -> LoadPrefill {
        let prescription = prescription(
            exerciseId: exerciseId,
            essential: essential,
            reps: reps,
            rir: rir,
            sets: 0,
            groups: []
        )
        return LoadPrefill(loadKg: prescription.loadKg, reason: prescription.reason ?? "none")
    }

    /// The full replacement prescription, matching `prescription_from_catalogue` on the server:
    /// a live erector dose overrides every other load and caps sets; the slot's group shape
    /// survives a normal substitution; a substituted slot never keeps top-set eligibility.
    public func prescription(
        exerciseId: String,
        essential: Bool,
        reps: Int,
        rir: Int?,
        sets: Int,
        groups: [SetGroup]
    ) -> CataloguePrescription {
        guard let entry = exercises[exerciseId] else {
            return CataloguePrescription(sets: sets, reason: "no_catalogue_entry")
        }
        var result = CataloguePrescription(
            sets: sets,
            topSet: TopSetStatus(status: "not_applicable", reasonCode: "substituted"),
            vbtTarget: entry.vbtTarget
        )
        if let dose = entry.doseLoadKg {
            let cap = entry.doseSetsCap
            result.loadKg = NSDecimalNumber(decimal: dose).doubleValue
            result.sets = cap.map { min(sets, $0) } ?? sets
            result.reason = "flare_dose"
            result.resolvedBy = "catalogue"
            return result
        }
        let increment = entry.incrementKg ?? 0
        if entry.bodyweight == true {
            result.loadKg = 0
            result.reason = "bodyweight"
            result.resolvedBy = "catalogue"
            result.groups = Self.shape(
                groups, e1rm: nil, load: 0, increment: increment
            )
            return result
        }
        if entry.power == true {
            result.reason = "power_work"
            return result
        }
        guard increment > 0 else {
            result.reason = "no_increment"
            return result
        }
        if essential {
            guard let base = entry.baseLoadKg else {
                result.reason = "no_catalogue_base"
                return result
            }
            let divisor = Decimal(1) + (Decimal(reps) + Decimal(rir ?? 0)) / Decimal(30)
            let rounded = LoadRounding.roundDown(base / divisor, increment: increment)
            result.loadKg = rounded
            result.reason = "catalogue_e1rm"
            result.resolvedBy = "catalogue"
            result.groups = Self.shape(
                groups, e1rm: base, load: Decimal(rounded), increment: increment
            )
            return result
        }
        guard let held = entry.accessoryLoadKg else {
            result.reason = "no_catalogue_working_load"
            return result
        }
        let rounded = LoadRounding.roundDown(held, increment: increment)
        result.loadKg = rounded
        result.reason = "catalogue_double_progression"
        result.resolvedBy = "catalogue"
        result.groups = Self.shape(
            groups, e1rm: nil, load: Decimal(rounded), increment: increment
        )
        return result
    }

    private static func shape(
        _ groups: [SetGroup],
        e1rm: Decimal?,
        load: Decimal,
        increment: Decimal
    ) -> [SetGroup] {
        groups.map { group in
            let reps = group.repsLow ?? 1
            let rir = group.rirTarget ?? 0
            let groupLoad: Double
            if let e1rm, increment > 0 {
                let divisor = Decimal(1) + (Decimal(reps) + Decimal(rir)) / Decimal(30)
                groupLoad = LoadRounding.roundDown(e1rm / divisor, increment: increment)
            } else {
                groupLoad = NSDecimalNumber(decimal: load).doubleValue
            }
            return SetGroup(
                groupIndex: group.groupIndex,
                sets: group.sets,
                loadKg: groupLoad,
                repsLow: group.repsLow,
                repsHigh: group.repsHigh,
                rirTarget: group.rirTarget
            )
        }
    }
}

public struct CataloguePrescription: Equatable, Sendable {
    public var loadKg: Double?
    public var sets: Int
    public var groups: [SetGroup] = []
    public var topSet: TopSetStatus?
    public var vbtTarget: ExecutionVBT?
    public var reason: String?
    public var resolvedBy: String?

    public init(
        loadKg: Double? = nil,
        sets: Int,
        groups: [SetGroup] = [],
        topSet: TopSetStatus? = nil,
        vbtTarget: ExecutionVBT? = nil,
        reason: String? = nil,
        resolvedBy: String? = nil
    ) {
        self.loadKg = loadKg
        self.sets = sets
        self.groups = groups
        self.topSet = topSet
        self.vbtTarget = vbtTarget
        self.reason = reason
        self.resolvedBy = resolvedBy
    }
}

public struct LoadCatalogueEntry: Codable, Equatable, Sendable {
    public let loadSource: String?
    public let baseLoadKg: Decimal?
    public let accessoryLoadKg: Decimal?
    public let incrementKg: Decimal?
    public let bodyweight: Bool?
    public let power: Bool?
    /// A live erector dose overrides every other load and caps the working sets.
    public let doseLoadKg: Decimal?
    public let doseSetsCap: Int?
    public let vbtTarget: ExecutionVBT?

    public init(
        loadSource: String? = nil,
        baseLoadKg: Decimal? = nil,
        accessoryLoadKg: Decimal? = nil,
        incrementKg: Decimal? = nil,
        bodyweight: Bool? = nil,
        power: Bool? = nil,
        doseLoadKg: Decimal? = nil,
        doseSetsCap: Int? = nil,
        vbtTarget: ExecutionVBT? = nil
    ) {
        self.loadSource = loadSource
        self.baseLoadKg = baseLoadKg
        self.accessoryLoadKg = accessoryLoadKg
        self.incrementKg = incrementKg
        self.bodyweight = bodyweight
        self.power = power
        self.doseLoadKg = doseLoadKg
        self.doseSetsCap = doseSetsCap
        self.vbtTarget = vbtTarget
    }

    private enum CodingKeys: String, CodingKey {
        case loadSource
        case baseLoadKg
        case accessoryLoadKg
        case incrementKg
        case bodyweight
        case power
        case doseLoadKg
        case doseSetsCap
        case vbtTarget
    }

    /// Decode through the shortest decimal string, matching `Decimal(str(load))` on the server.
    /// Decoding straight into `Decimal` can carry a binary artifact (82.5 became 82.499…), which
    /// would round a value that lands exactly on an increment down by one step.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        loadSource = try container.decodeIfPresent(String.self, forKey: .loadSource)
        baseLoadKg = Self.decimal(try container.decodeIfPresent(Double.self, forKey: .baseLoadKg))
        accessoryLoadKg = Self.decimal(
            try container.decodeIfPresent(Double.self, forKey: .accessoryLoadKg)
        )
        incrementKg = Self.decimal(
            try container.decodeIfPresent(Double.self, forKey: .incrementKg)
        )
        bodyweight = try container.decodeIfPresent(Bool.self, forKey: .bodyweight)
        power = try container.decodeIfPresent(Bool.self, forKey: .power)
        doseLoadKg = Self.decimal(
            try container.decodeIfPresent(Double.self, forKey: .doseLoadKg)
        )
        doseSetsCap = try container.decodeIfPresent(Int.self, forKey: .doseSetsCap)
        vbtTarget = try container.decodeIfPresent(ExecutionVBT.self, forKey: .vbtTarget)
    }

    private static func decimal(_ value: Double?) -> Decimal? {
        guard let value else { return nil }
        return Decimal(string: String(value))
    }
}

public struct LoadPrefill: Equatable, Sendable {
    public let loadKg: Double?
    public let reason: String

    public init(loadKg: Double?, reason: String) {
        self.loadKg = loadKg
        self.reason = reason
    }

    public var hasValue: Bool { loadKg != nil }
}

public enum LoadRounding {
    /// The largest multiple of `increment` not greater than `value`, in decimal arithmetic.
    /// Mirrors `strength_coach.prescribe.loads.round_down`.
    public static func roundDown(_ value: Decimal, increment: Decimal) -> Double {
        guard increment > 0 else { return NSDecimalNumber(decimal: value).doubleValue }
        var quotient: Decimal = value / increment
        var steps = Decimal()
        NSDecimalRound(&steps, &quotient, 0, .down)
        let product: Decimal = steps * increment
        return NSDecimalNumber(decimal: product).doubleValue
    }

    public static func roundDown(_ value: Double, increment: Double) -> Double {
        guard increment > 0 else { return value }
        return roundDown(Decimal(string: String(value)) ?? Decimal(value),
                         increment: Decimal(string: String(increment)) ?? Decimal(increment))
    }
}

/// The plan-side cache of everything a start needs while the server is unreachable. The watch
/// receives it by `transferFile`; the phone keeps the same shape on disk so a relaunch does not
/// lose an issued plan before it is started.
public struct CachedIssuedPlan: Codable, Sendable {
    public let issuedPlanId: String
    public let executionId: String
    public let forDate: String
    public let sessionType: String
    public let expiresAt: String
    public let plan: PrescriptionPlan
    public let readiness: ReadinessScore?
    public let warnings: [String]
    public let loadCatalogue: LoadCatalogue?
    public let cachedAt: String

    public init(
        issuedPlanId: String,
        executionId: String,
        forDate: String,
        sessionType: String,
        expiresAt: String,
        plan: PrescriptionPlan,
        readiness: ReadinessScore? = nil,
        warnings: [String] = [],
        loadCatalogue: LoadCatalogue? = nil,
        cachedAt: String = ExecutionEvent.nowISO()
    ) {
        self.issuedPlanId = issuedPlanId
        self.executionId = executionId
        self.forDate = forDate
        self.sessionType = sessionType
        self.expiresAt = expiresAt
        self.plan = plan
        self.readiness = readiness
        self.warnings = warnings
        self.loadCatalogue = loadCatalogue
        self.cachedAt = cachedAt
    }

    public var issued: IssuedPlanResponse {
        IssuedPlanResponse(
            issuedPlanId: issuedPlanId,
            forDate: forDate,
            sessionType: sessionType,
            expiresAt: expiresAt,
            plan: plan,
            readiness: readiness,
            warnings: warnings,
            executionID: executionId,
            loadCatalogue: loadCatalogue
        )
    }

    public var isExpired: Bool {
        guard let date = ISO8601DateFormatter().date(from: expiresAt) else { return false }
        return date < Date()
    }
}

/// The file the phone sends to the watch. One decoded value is both the offline start input and
/// the catalogue a watch-side substitution would need (watch-authored changes stay out of scope).
public struct WatchPlanCache: Codable, Sendable {
    public static let envelopeVersion = 1

    public let version: Int
    public let issuedPlanId: String
    public let executionId: String
    public let forDate: String
    public let sessionType: String
    public let expiresAt: String
    public let plan: PrescriptionPlan
    public let loadCatalogue: LoadCatalogue?
    public let warnings: [String]
    public let deliveredAt: String

    public init(
        issuedPlanId: String,
        executionId: String,
        forDate: String,
        sessionType: String,
        expiresAt: String,
        plan: PrescriptionPlan,
        loadCatalogue: LoadCatalogue? = nil,
        warnings: [String] = [],
        deliveredAt: String = ExecutionEvent.nowISO()
    ) {
        self.version = Self.envelopeVersion
        self.issuedPlanId = issuedPlanId
        self.executionId = executionId
        self.forDate = forDate
        self.sessionType = sessionType
        self.expiresAt = expiresAt
        self.plan = plan
        self.loadCatalogue = loadCatalogue
        self.warnings = warnings
        self.deliveredAt = deliveredAt
    }

    public init(cached: CachedIssuedPlan) {
        self.init(
            issuedPlanId: cached.issuedPlanId,
            executionId: cached.executionId,
            forDate: cached.forDate,
            sessionType: cached.sessionType,
            expiresAt: cached.expiresAt,
            plan: cached.plan,
            loadCatalogue: cached.loadCatalogue,
            warnings: cached.warnings
        )
    }

    public var summary: WatchPlanSummary {
        WatchPlanMapper.summary(from: self)
    }

    public var isExpired: Bool {
        guard let date = ISO8601DateFormatter().date(from: expiresAt) else { return false }
        return date < Date()
    }
}

public enum WatchPlanMapper {
    public static func summary(from cache: WatchPlanCache) -> WatchPlanSummary {
        WatchPlanSummary(
            issuedPlanID: cache.issuedPlanId,
            forDate: cache.forDate,
            sessionType: cache.sessionType,
            items: cache.plan.items.map { item in
                WatchPlanItemSummary(
                    id: item.id,
                    exerciseLabel: humanized(item.exerciseId),
                    setsLabel: item.sets.map(String.init) ?? "—",
                    repsLabel: item.repsLabel,
                    loadLabel: item.loadLabel,
                    effortLabel: item.effortLabel,
                    restLabel: item.restS.map { String($0) + "s rest" } ?? "—",
                    warmupLabel: {
                        guard let warmup = item.warmup, !warmup.isEmpty else { return nil }
                        return warmup.map { "\($0.loadLabel)×\($0.reps)" }.joined(separator: " · ")
                    }()
                )
            },
            warnings: cache.warnings,
            expiresAt: cache.expiresAt,
            executionID: cache.executionId
        )
    }

    private static func humanized(_ exerciseId: String?) -> String {
        guard let exerciseId, !exerciseId.isEmpty else { return "Exercise" }
        return exerciseId
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
