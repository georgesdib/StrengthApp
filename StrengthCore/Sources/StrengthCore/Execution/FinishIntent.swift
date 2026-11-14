import Foundation

/// HealthKit finalisation state for a finished watch session (contract §12.2). 6.3 records the
/// field but never saves a workout; the save itself belongs to 6.5.
public enum HealthKitSaveState: String, Codable, Sendable {
    case pending
    case saved
    case unsaved
}

/// Persisted before the server finish is attempted, so an offline or suspended finish can be
/// replayed without losing the real end time or the effort rating.
public struct FinishIntent: Codable, Equatable, Sendable {
    public let endedAt: Date
    /// Session RPE as recorded on the watch. Nil means the lifter marked it not recorded.
    public let sessionRpe: Double?
    public var hkState: HealthKitSaveState
    public var serverAcked: Bool
    /// Automatic save attempts so far; optional so earlier records still decode.
    public var hkAttempts: Int?
    /// The lifter dismissed the unsaved notice; keeps the truth but stops nagging.
    public var hkNoticeDismissed: Bool?
    /// Delivery of the optional effort sample, tracked separately from the workout.
    public var effortState: EffortDeliveryState?
    public var effortAttempts: Int?

    public init(
        endedAt: Date,
        sessionRpe: Double?,
        hkState: HealthKitSaveState = .pending,
        serverAcked: Bool = false,
        hkAttempts: Int? = 0,
        hkNoticeDismissed: Bool? = false,
        effortState: EffortDeliveryState? = nil,
        effortAttempts: Int? = 0
    ) {
        self.endedAt = endedAt
        self.sessionRpe = sessionRpe
        self.hkState = hkState
        self.serverAcked = serverAcked
        self.hkAttempts = hkAttempts
        self.hkNoticeDismissed = hkNoticeDismissed
        self.effortState = effortState
        self.effortAttempts = effortAttempts
    }
}
