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
        guard let entry = exercises[exerciseId] else {
            return LoadPrefill(loadKg: nil, reason: "no_catalogue_entry")
        }
        if entry.bodyweight == true {
            return LoadPrefill(loadKg: 0, reason: "bodyweight")
        }
        if entry.power == true {
            return LoadPrefill(loadKg: nil, reason: "power_work")
        }
        guard let increment = entry.incrementKg, increment > 0 else {
            return LoadPrefill(loadKg: nil, reason: "no_increment")
        }
        let raw: Decimal
        let reason: String
        if essential {
            guard let base = entry.baseLoadKg else {
                return LoadPrefill(loadKg: nil, reason: "no_catalogue_base")
            }
            // Missing RIR falls back to plain Epley (reps / 30), matching estimate_e1rm.
            let divisor = Decimal(1) + (Decimal(reps) + Decimal(rir ?? 0)) / Decimal(30)
            raw = base / divisor
            reason = "catalogue_e1rm"
        } else {
            guard let held = entry.accessoryLoadKg else {
                return LoadPrefill(loadKg: nil, reason: "no_catalogue_working_load")
            }
            raw = held
            reason = "catalogue_double_progression"
        }
        let rounded = LoadRounding.roundDown(raw, increment: increment)
        return LoadPrefill(loadKg: rounded, reason: reason)
    }
}

public struct LoadCatalogueEntry: Codable, Equatable, Sendable {
    public let loadSource: String?
    public let baseLoadKg: Decimal?
    public let accessoryLoadKg: Decimal?
    public let incrementKg: Decimal?
    public let bodyweight: Bool?
    public let power: Bool?

    public init(
        loadSource: String? = nil,
        baseLoadKg: Decimal? = nil,
        accessoryLoadKg: Decimal? = nil,
        incrementKg: Decimal? = nil,
        bodyweight: Bool? = nil,
        power: Bool? = nil
    ) {
        self.loadSource = loadSource
        self.baseLoadKg = baseLoadKg
        self.accessoryLoadKg = accessoryLoadKg
        self.incrementKg = incrementKg
        self.bodyweight = bodyweight
        self.power = power
    }

    private enum CodingKeys: String, CodingKey {
        case loadSource
        case baseLoadKg
        case accessoryLoadKg
        case incrementKg
        case bodyweight
        case power
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
    public let executionTarget: String?
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
        executionTarget: String? = nil,
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
        self.executionTarget = executionTarget
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
            executionTarget: executionTarget,
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
    public let executionTarget: String?
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
        executionTarget: String? = nil,
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
        self.executionTarget = executionTarget
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
            warnings: cached.warnings,
            executionTarget: cached.executionTarget
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
            executionTarget: cache.executionTarget ?? "watch",
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
