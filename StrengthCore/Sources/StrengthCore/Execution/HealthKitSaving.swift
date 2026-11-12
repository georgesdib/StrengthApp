import Foundation

/// The watch's HealthKit seam. The engine and finaliser depend on this, never on HealthKit, so the
/// exactly-once save matrix is testable on the iPhone suite; the real recorder lives in the watch
/// target and is exercised on hardware.
@MainActor
public protocol HealthKitSaving: AnyObject {
    /// True only when a live builder created for this session in this process can still finish.
    var hasLiveBuilder: Bool { get }

    /// True when a workout with this external UUID exists. Throws when the check could not be
    /// completed: absence must be established, never assumed.
    func hasWorkout(externalUUID: String) async throws -> Bool

    /// Ends collection and finishes the live builder with the external UUID and original end.
    func finishLiveWorkout(externalUUID: String, endedAt: Date) async throws

    /// Saves one minimal, backdated workout with no samples (contract §12.3).
    func saveMinimalWorkout(
        externalUUID: String,
        startedAt: Date,
        endedAt: Date
    ) async throws

    /// Writes the effort sample for an existing workout. Never creates a second workout.
    func saveEffort(externalUUID: String, effort: Double) async throws

    /// Ends the live session without saving anything (abandon).
    func endWithoutSaving() async
}

/// Why a HealthKit save failed, in terms the retry policy understands.
public enum HealthKitSaveFailure: Error, Equatable, Sendable {
    /// Retrying cannot succeed: authorisation, entitlement or an invalid request.
    case definitive(String)
    /// Worth another attempt on a later launch or foreground.
    case transient(String)
}

/// Delivery of the optional effort sample, independent from the workout itself.
public enum EffortDeliveryState: String, Codable, Sendable, Equatable {
    case pending
    case saved
    case unavailable
}

public struct HealthKitFinalizationOutcome: Equatable, Sendable {
    public let state: HealthKitSaveState
    public let attempts: Int
    public let failure: String?
    public let effortState: EffortDeliveryState?
    public let effortAttempts: Int?

    public init(
        state: HealthKitSaveState,
        attempts: Int,
        failure: String?,
        effortState: EffortDeliveryState? = nil,
        effortAttempts: Int? = nil
    ) {
        self.state = state
        self.attempts = attempts
        self.failure = failure
        self.effortState = effortState
        self.effortAttempts = effortAttempts
    }
}

/// The exactly-once save rule (contract §12.2/§12.3), independent of HealthKit.
@MainActor
public enum HealthKitFinalizer {
    /// Automatic attempts before a pending save becomes unsaved. A manual retry is not capped.
    public static let maxAttempts = 5

    public static func finalize(
        externalUUID: String,
        startedAt: Date,
        endedAt: Date,
        effort: Double?,
        state: HealthKitSaveState,
        attempts: Int,
        effortState: EffortDeliveryState?,
        effortAttempts: Int?,
        manual: Bool,
        recorder: HealthKitSaving
    ) async -> HealthKitFinalizationOutcome {
        var workoutState = state
        var workoutAttempts = attempts

        if state == .unsaved && !manual {
            // Unsaved is terminal for automatic retries; only an explicit Try again may run.
            return HealthKitFinalizationOutcome(
                state: .unsaved,
                attempts: attempts,
                failure: nil,
                effortState: effortState,
                effortAttempts: effortAttempts
            )
        }

        var failure: String?
        if workoutState != .saved {
            do {
                if try await recorder.hasWorkout(externalUUID: externalUUID) {
                    workoutState = .saved
                } else if recorder.hasLiveBuilder {
                    try await recorder.finishLiveWorkout(
                        externalUUID: externalUUID, endedAt: endedAt
                    )
                    workoutState = .saved
                } else {
                    try await recorder.saveMinimalWorkout(
                        externalUUID: externalUUID,
                        startedAt: startedAt,
                        endedAt: endedAt
                    )
                    workoutState = .saved
                }
            } catch let saveFailure as HealthKitSaveFailure {
                switch saveFailure {
                case .definitive(let message):
                    workoutState = .unsaved
                    failure = message
                case .transient(let message):
                    workoutAttempts += 1
                    failure = message
                    workoutState = workoutAttempts >= maxAttempts ? .unsaved : .pending
                }
            } catch {
                workoutAttempts += 1
                failure = error.localizedDescription
                workoutState = workoutAttempts >= maxAttempts ? .unsaved : .pending
            }
        }

        // Effort is only meaningful once the workout exists, and never re-creates the workout.
        var resolvedEffortState = effortState
        var resolvedEffortAttempts = effortAttempts ?? 0
        var effortFailure: String?
        if workoutState == .saved, let effort, resolvedEffortState != .saved,
           resolvedEffortState != .unavailable {
            do {
                try await recorder.saveEffort(externalUUID: externalUUID, effort: effort)
                resolvedEffortState = .saved
            } catch let saveFailure as HealthKitSaveFailure {
                switch saveFailure {
                case .definitive(let message):
                    resolvedEffortState = .unavailable
                    effortFailure = message
                case .transient(let message):
                    resolvedEffortAttempts += 1
                    effortFailure = message
                    resolvedEffortState = resolvedEffortAttempts >= maxAttempts
                        ? .unavailable : .pending
                }
            } catch {
                resolvedEffortAttempts += 1
                effortFailure = error.localizedDescription
                resolvedEffortState = resolvedEffortAttempts >= maxAttempts
                    ? .unavailable : .pending
            }
        }
        if resolvedEffortState == nil, effort != nil {
            resolvedEffortState = .pending
        }

        return HealthKitFinalizationOutcome(
            state: workoutState,
            attempts: workoutAttempts,
            failure: failure ?? effortFailure,
            effortState: resolvedEffortState,
            effortAttempts: resolvedEffortAttempts
        )
    }
}

/// Both legs of HealthKit startup must succeed before the app may start a server workout: the
/// session reaching `.running` and the builder beginning collection are independent.
public struct HealthKitStartGate: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case waiting
        case ready
        case failed(String)
    }

    private var sessionRunning = false
    private var collectionBegan = false
    private var failure: String?

    public init() {}

    public var outcome: Outcome {
        if let failure { return .failed(failure) }
        return sessionRunning && collectionBegan ? .ready : .waiting
    }

    public mutating func sessionStarted() -> Outcome {
        sessionRunning = true
        return outcome
    }

    public mutating func collectionStarted() -> Outcome {
        collectionBegan = true
        return outcome
    }

    public mutating func failed(_ message: String) -> Outcome {
        failure = message
        return outcome
    }
}

/// A heart-rate reading with the moment it was observed, so a stale value is never shown as live.
public struct HeartRateReading: Equatable, Sendable {
    public static let freshness: TimeInterval = 30

    public let bpm: Int
    public let observedAt: Date

    public init(bpm: Int, observedAt: Date) {
        self.bpm = bpm
        self.observedAt = observedAt
    }

    public func isFresh(at date: Date) -> Bool {
        date.timeIntervalSince(observedAt) <= Self.freshness
    }
}
