import Foundation

/// The watch's durable record for one execution session (contract §11).
///
/// Stored inside `OfflineCapture` so the session snapshot, its revision, the rest interval and
/// the finish intent survive suspension and relaunch alongside the operation queue. HealthKit
/// workout identity is the `sessionUUID`; the server never learns it.
public struct WatchSessionRecord: Codable, Equatable, Sendable {
    public var sessionUUID: String
    public var startedAt: Date
    /// The plan revision the snapshot was built from. The watch never writes plan content.
    public var planRevision: Int?
    /// The derived server offset, persisted so a relaunch keeps honest timestamps.
    public var clockOffsetSeconds: TimeInterval?
    public var rest: RestInterval?
    public var finish: FinishIntent?

    public init(
        sessionUUID: String,
        startedAt: Date,
        planRevision: Int? = nil,
        clockOffsetSeconds: TimeInterval? = nil,
        rest: RestInterval? = nil,
        finish: FinishIntent? = nil
    ) {
        self.sessionUUID = sessionUUID
        self.startedAt = startedAt
        self.planRevision = planRevision
        self.clockOffsetSeconds = clockOffsetSeconds
        self.rest = rest
        self.finish = finish
    }

    public var clock: ServerClock? {
        clockOffsetSeconds.map(ServerClock.init(offset:))
    }
}
