import Foundation

/// A read-only plan summary for the watch. It contains no execution controls.
public struct WatchPlanItemSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let exerciseLabel: String
    public let setsLabel: String
    public let repsLabel: String
    public let loadLabel: String
    public let effortLabel: String
    public let restLabel: String
    public let warmupLabel: String?

    public init(
        id: String,
        exerciseLabel: String,
        setsLabel: String,
        repsLabel: String,
        loadLabel: String,
        effortLabel: String,
        restLabel: String,
        warmupLabel: String? = nil
    ) {
        self.id = id
        self.exerciseLabel = exerciseLabel
        self.setsLabel = setsLabel
        self.repsLabel = repsLabel
        self.loadLabel = loadLabel
        self.effortLabel = effortLabel
        self.restLabel = restLabel
        self.warmupLabel = warmupLabel
    }
}

public struct WatchPlanSummary: Equatable, Sendable {
    public let issuedPlanID: String
    public let forDate: String
    public let sessionType: String
    public let items: [WatchPlanItemSummary]
    public let warnings: [String]
    public let expiresAt: String?
    public let executionTarget: String

    public init(
        issuedPlanID: String,
        forDate: String,
        sessionType: String,
        items: [WatchPlanItemSummary],
        warnings: [String],
        expiresAt: String?,
        executionTarget: String
    ) {
        self.issuedPlanID = issuedPlanID
        self.forDate = forDate
        self.sessionType = sessionType
        self.items = items
        self.warnings = warnings
        self.expiresAt = expiresAt
        self.executionTarget = executionTarget
    }
}

/// What today's readiness says, reduced to what a glance needs. The server owns every number
/// here; this type only formats them for the wrist.
public struct WatchReadinessSummary: Equatable, Sendable {
    public let statusWord: String
    /// The server's score, as a percentage. nil when the day has no score yet.
    public let scoreText: String?
    /// At most two drivers, heaviest first, e.g. "Sleep 7.4 h".
    public let drivers: [String]

    public init(statusWord: String, scoreText: String?, drivers: [String]) {
        self.statusWord = statusWord
        self.scoreText = scoreText
        self.drivers = drivers
    }

    public static func make(_ score: ReadinessScore?) -> WatchReadinessSummary? {
        guard let score else { return nil }
        let drivers = (score.components ?? [])
            .sorted { $0.weight > $1.weight }
            .prefix(2)
            .map { component in
                let value = Self.valueText(component)
                let name = Self.fieldLabel(component.field)
                return value.isEmpty ? name : "\(name) \(value)"
            }
        return WatchReadinessSummary(
            statusWord: Self.statusWord(score.status),
            scoreText: score.score.map { "\(Int(($0 * 100).rounded()))%" },
            drivers: Array(drivers)
        )
    }

    /// The server's word, not a client-made judgement.
    static func statusWord(_ status: String) -> String {
        switch status {
        case "ready": return "Ready"
        case "insufficient": return "Not scored yet"
        case "unknown": return "Not scored yet"
        default: return status.capitalized
        }
    }

    static func fieldLabel(_ field: String) -> String {
        switch field {
        case "sleep_hours", "sleep": return "Sleep"
        case "hrv_ms", "hrv": return "HRV"
        case "rhr_bpm", "rhr", "resting_hr": return "RHR"
        case "bodyweight_kg", "bodyweight": return "Weight"
        default:
            return field
                .split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    static func valueText(_ component: ReadinessComponent) -> String {
        switch component.field {
        case "sleep_hours", "sleep":
            return String(format: "%.1f h", component.value)
        case "hrv_ms", "hrv":
            return "\(Int(component.value.rounded())) ms"
        case "rhr_bpm", "rhr", "resting_hr":
            return "\(Int(component.value.rounded())) bpm"
        case "bodyweight_kg", "bodyweight":
            return String(format: "%.1f kg", component.value)
        default:
            return String(format: "%.1f", component.value)
        }
    }
}

/// The three questions an empty Today has to answer: how am I, why is there nothing, what now.
public struct WatchTodayEmptyCopy: Equatable, Sendable {
    public let title: String
    public let detail: String?
    public let action: String?
    public let identifier: String

    public init(title: String, detail: String?, action: String?, identifier: String) {
        self.title = title
        self.detail = detail
        self.action = action
        self.identifier = identifier
    }
}

public enum WatchTodayCopy {
    /// nil when the screen is not empty: a plan is there, or the screen is still working.
    public static func empty(for state: WatchTodayState) -> WatchTodayEmptyCopy? {
        switch state {
        case .ready, .loading, .generating:
            return nil
        case .missingCredentials:
            return WatchTodayEmptyCopy(
                title: "Not paired",
                detail: "This watch has no credential for your Home Server.",
                action: "Open Strength on your iPhone to pair it.",
                identifier: "unpaired"
            )
        case .noPlan:
            return WatchTodayEmptyCopy(
                title: "No workout today",
                detail: "No workout has been requested for this date.",
                action: "Request one on your iPhone.",
                identifier: "no-plan"
            )
        case .phonePlan:
            return WatchTodayEmptyCopy(
                title: "Planned for iPhone",
                detail: "Today's workout is set to run on your iPhone.",
                action: "Start it there.",
                identifier: "phone-plan"
            )
        case .unsupportedTarget:
            return WatchTodayEmptyCopy(
                title: "Not for Apple Watch",
                detail: "This plan was issued for another device.",
                action: nil,
                identifier: "unsupported"
            )
        case .offline(_, let detail):
            return WatchTodayEmptyCopy(
                title: "Can't reach your Home Server",
                detail: detail,
                action: nil,
                identifier: "offline"
            )
        case .unavailable(let text):
            return WatchTodayEmptyCopy(
                title: "Plan unavailable",
                detail: text,
                action: nil,
                identifier: "unavailable"
            )
        }
    }
}

public enum WatchTodayState: Equatable, Sendable {
    case loading
    case missingCredentials
    case noPlan
    case phonePlan
    case unsupportedTarget
    case generating(elapsedSeconds: Int?)
    case ready(WatchPlanSummary)
    /// The request failed. The detail is the reason and the host that was tried, so a stale
    /// home-server address, a refused scheme and a genuinely offline watch do not all read as
    /// "connect to Wi-Fi".
    case offline(WatchPlanSummary?, detail: String?)
    case unavailable(String)
}

/// Names the server the watch tried before the reason, so "cannot reach it" is not confused
/// with a stale address or a scheme the system refuses.
public enum WatchOfflineDetail {
    public static func make(baseURL: String, reason: String?) -> String {
        let host = URL(string: baseURL)?.host ?? baseURL
        guard let reason, !reason.isEmpty else { return host }
        return "\(host) — \(reason)"
    }
}

public enum WatchTodayMapper {
    public static func map(_ state: PlansStateResponse) -> WatchTodayState {
        let target = state.executionTarget
        switch state.status {
        case "none":
            return .noPlan
        case "queued", "building":
            switch target {
            case "watch":
                return .generating(elapsedSeconds: state.elapsedSeconds)
            case "phone":
                return .phonePlan
            default:
                return .unsupportedTarget
            }
        case "ready":
            guard target == "watch" else {
                return target == "phone" ? .phonePlan : .unsupportedTarget
            }
            guard let plan = state.plan else {
                return .unavailable("The server marked a plan ready without a plan body.")
            }
            let items = plan.items.map { item in
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
                        return warmup
                            .map { "\($0.loadLabel)×\($0.reps)" }
                            .joined(separator: " · ")
                    }()
                )
            }
            return .ready(WatchPlanSummary(
                issuedPlanID: state.issuedPlanId ?? "",
                forDate: state.forDate ?? plan.forDate ?? "",
                sessionType: state.sessionType ?? plan.sessionType ?? "Workout",
                items: items,
                warnings: state.warnings ?? plan.warnings ?? [],
                expiresAt: state.planExpiresAt,
                executionTarget: "watch"
            ))
        default:
            return .unavailable("The server returned an unknown plan state.")
        }
    }

    private static func humanized(_ exerciseId: String?) -> String {
        guard let exerciseId, !exerciseId.isEmpty else { return "Exercise" }
        return exerciseId
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

public struct WatchTodaySnapshot: Equatable, Sendable {
    public let state: WatchTodayState
    public let serverDate: String?
    /// The readiness the plan read already carries, so no extra request is needed.
    public let readiness: WatchReadinessSummary?

    public init(
        state: WatchTodayState,
        serverDate: String?,
        readiness: WatchReadinessSummary? = nil
    ) {
        self.state = state
        self.serverDate = serverDate
        self.readiness = readiness
    }
}

/// Fetches the watch's read-only Today data from its Home server session. It uses the same
/// IOSAPIClient/IOSSession as the phone but never requests or writes a workout.
@MainActor
public final class WatchTodayService {
    private let client: IOSAPIClient

    public init(client: IOSAPIClient) {
        self.client = client
    }

    public func fetch(session: IOSSession) async throws -> WatchTodaySnapshot {
        async let bootstrap = client.bootstrap(session: session)
        async let plan = client.planState(session: session)
        let (server, planState) = try await (bootstrap, plan)
        return WatchTodaySnapshot(
            state: WatchTodayMapper.map(planState),
            serverDate: server.serverDate,
            readiness: WatchReadinessSummary.make(planState.readiness)
        )
    }
}
