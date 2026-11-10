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

    public init(
        id: String,
        exerciseLabel: String,
        setsLabel: String,
        repsLabel: String,
        loadLabel: String,
        effortLabel: String,
        restLabel: String
    ) {
        self.id = id
        self.exerciseLabel = exerciseLabel
        self.setsLabel = setsLabel
        self.repsLabel = repsLabel
        self.loadLabel = loadLabel
        self.effortLabel = effortLabel
        self.restLabel = restLabel
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

public enum WatchTodayState: Equatable, Sendable {
    case loading
    case missingCredentials
    case noPlan
    case phonePlan
    case generating(elapsedSeconds: Int?)
    case ready(WatchPlanSummary)
    case offline(WatchPlanSummary?)
    case unavailable(String)
}

public enum WatchTodayMapper {
    public static func map(_ state: PlansStateResponse) -> WatchTodayState {
        let target = state.executionTarget ?? "watch"
        switch state.status {
        case "none":
            return .noPlan
        case "queued", "building":
            return target == "phone" ? .phonePlan : .generating(elapsedSeconds: state.elapsedSeconds)
        case "ready":
            guard target == "watch" else {
                return .phonePlan
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
                    restLabel: item.restS.map { String($0) + "s rest" } ?? "—"
                )
            }
            return .ready(WatchPlanSummary(
                issuedPlanID: state.issuedPlanId ?? "",
                forDate: state.forDate ?? plan.forDate ?? "",
                sessionType: state.sessionType ?? plan.sessionType ?? "Workout",
                items: items,
                warnings: state.warnings ?? plan.warnings ?? [],
                expiresAt: state.planExpiresAt,
                executionTarget: target
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

    public init(state: WatchTodayState, serverDate: String?) {
        self.state = state
        self.serverDate = serverDate
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
            serverDate: server.serverDate
        )
    }
}
