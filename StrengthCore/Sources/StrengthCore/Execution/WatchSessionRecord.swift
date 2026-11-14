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
    /// The lifter's adjustments, persisted so a termination mid-set does not lose them.
    public var loadKg: Double?
    public var reps: Int?

    public init(
        localSetID: String,
        planItemIndex: Int,
        setIndex: Int,
        startedAt: Date,
        loadKg: Double? = nil,
        reps: Int? = nil
    ) {
        self.localSetID = localSetID
        self.planItemIndex = planItemIndex
        self.setIndex = setIndex
        self.startedAt = startedAt
        self.loadKg = loadKg
        self.reps = reps
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
    /// The exercise the lifter selected from the list, persisted so a relaunch returns to it.
    public var selectedItemIndex: Int?
    /// Set when a set was preserved off-plan because the phone changed the item while offline.
    public var offPlanNoted: Bool?
    /// The plan item whose exercise is currently in progress, for exercise telemetry.
    public var exerciseItemIndex: Int?
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
        eventSetIDs: [String: Int]? = nil,
        selectedItemIndex: Int? = nil,
        exerciseItemIndex: Int? = nil,
        offPlanNoted: Bool? = nil
    ) {
        self.sessionUUID = sessionUUID
        self.startedAt = startedAt
        self.planRevision = planRevision
        self.clockOffsetSeconds = clockOffsetSeconds
        self.rest = rest
        self.finish = finish
        self.activeSet = activeSet
        self.eventSetIDs = eventSetIDs
        self.selectedItemIndex = selectedItemIndex
        self.exerciseItemIndex = exerciseItemIndex
        self.offPlanNoted = offPlanNoted
    }

    public var clock: ServerClock? {
        clockOffsetSeconds.map(ServerClock.init(offset:))
    }

    /// The session's clock domain: every timestamp stored for this session was captured in
    /// server-adjusted terms, so all durations must be measured with this now.
    public func serverNow(at local: Date) -> Date {
        clock?.serverNow(from: local) ?? local
    }

    /// Elapsed session time measured in server-adjusted terms, so a fast or slow watch clock
    /// cannot distort it (contract §8).
    public func elapsedSeconds(at local: Date) -> TimeInterval {
        max(0, serverNow(at: local).timeIntervalSince(startedAt))
    }

    /// Duration of the set in progress, in the same clock domain as its `startedAt`.
    public func setDuration(setStartedAt: Date, at local: Date) -> TimeInterval {
        max(0, serverNow(at: local).timeIntervalSince(setStartedAt))
    }

    /// Remaining rest, measured against a server-adjusted now so a non-zero offset cannot finish
    /// a rest early or extend it.
    public func restRemaining(at local: Date) -> TimeInterval? {
        guard let rest, rest.isOpen else { return nil }
        return rest.remaining(at: serverNow(at: local))
    }

    public func restIsComplete(at local: Date) -> Bool {
        guard let rest, rest.isOpen else { return false }
        return rest.isComplete(at: serverNow(at: local))
    }
}
