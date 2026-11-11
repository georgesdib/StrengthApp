import Foundation

/// The watch's durable record for one execution session (contract §11).
///
/// Stored inside `OfflineCapture` so the session snapshot, its revision, the rest interval and
/// the finish intent survive suspension and relaunch alongside the operation queue. HealthKit
/// workout identity is the `sessionUUID`; the server never learns it.
public struct ActiveSet: Codable, Equatable, Sendable {
    /// Also the idempotency key of the add-set request and the `local_set_id` of its events.
    public var localSetID: String
    public var planItemIndex: Int
    public var setIndex: Int
    public var startedAt: Date

    public init(localSetID: String, planItemIndex: Int, setIndex: Int, startedAt: Date) {
        self.localSetID = localSetID
        self.planItemIndex = planItemIndex
        self.setIndex = setIndex
        self.startedAt = startedAt
    }
}

public struct WatchSessionRecord: Codable, Equatable, Sendable {
    public var sessionUUID: String
    public var startedAt: Date
    /// The plan revision the snapshot was built from. The watch never writes plan content.
    public var planRevision: Int?
    /// The derived server offset, persisted so a relaunch keeps honest timestamps.
    public var clockOffsetSeconds: TimeInterval?
    public var rest: RestInterval?
    public var finish: FinishIntent?
    /// The set the lifter explicitly began, before it is logged.
    public var activeSet: ActiveSet?
    /// local set id -> server set id, learned when the add-set is acknowledged. Used only to
    /// attach `set_id` to the matching telemetry event; a missing entry sends no set id.
    public var eventSetIDs: [String: Int]?

    public init(
        sessionUUID: String,
        startedAt: Date,
        planRevision: Int? = nil,
        clockOffsetSeconds: TimeInterval? = nil,
        rest: RestInterval? = nil,
        finish: FinishIntent? = nil,
        activeSet: ActiveSet? = nil,
        eventSetIDs: [String: Int]? = nil
    ) {
        self.sessionUUID = sessionUUID
        self.startedAt = startedAt
        self.planRevision = planRevision
        self.clockOffsetSeconds = clockOffsetSeconds
        self.rest = rest
        self.finish = finish
        self.activeSet = activeSet
        self.eventSetIDs = eventSetIDs
    }

    public var clock: ServerClock? {
        clockOffsetSeconds.map(ServerClock.init(offset:))
    }
}
