import Foundation

/// The watch's HealthKit seam. The engine and finaliser depend on this, never on HealthKit, so the
/// exactly-once save matrix is testable on the iPhone suite; the real recorder lives in the watch
/// target and is exercised on hardware.
@MainActor
public protocol HealthKitSaving: AnyObject {
    /// True when a live builder from this process can still finish its workout.
    var hasLiveBuilder: Bool { get }

    /// A workout with this external UUID already exists in Health.
    func hasWorkout(externalUUID: String) async -> Bool

    /// Ends collection and finishes the live builder with the external UUID and original dates.
    func finishLiveWorkout(
        externalUUID: String,
        endedAt: Date,
        effort: Double?
    ) async throws

    /// Saves one minimal, backdated workout with no samples (contract §12.3).
    func saveMinimalWorkout(
        externalUUID: String,
        startedAt: Date,
        endedAt: Date,
        effort: Double?
    ) async throws

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

public struct HealthKitFinalizationOutcome: Equatable, Sendable {
    public let state: HealthKitSaveState
    public let attempts: Int
    public let failure: String?

    public init(state: HealthKitSaveState, attempts: Int, failure: String?) {
        self.state = state
        self.attempts = attempts
        self.failure = failure
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
        manual: Bool,
        recorder: HealthKitSaving
    ) async -> HealthKitFinalizationOutcome {
        if state == .saved {
            return HealthKitFinalizationOutcome(state: .saved, attempts: attempts, failure: nil)
        }
        if state == .unsaved && !manual {
            // Unsaved is terminal for automatic retries; only an explicit Try again may run.
            return HealthKitFinalizationOutcome(state: .unsaved, attempts: attempts, failure: nil)
        }
        // The external UUID is the exactly-once mechanism: an existing workout wins.
        if await recorder.hasWorkout(externalUUID: externalUUID) {
            return HealthKitFinalizationOutcome(state: .saved, attempts: attempts, failure: nil)
        }
        do {
            if recorder.hasLiveBuilder {
                try await recorder.finishLiveWorkout(
                    externalUUID: externalUUID, endedAt: endedAt, effort: effort
                )
            } else {
                try await recorder.saveMinimalWorkout(
                    externalUUID: externalUUID,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    effort: effort
                )
            }
            return HealthKitFinalizationOutcome(state: .saved, attempts: attempts, failure: nil)
        } catch let failure as HealthKitSaveFailure {
            switch failure {
            case .definitive(let message):
                return HealthKitFinalizationOutcome(
                    state: .unsaved, attempts: attempts, failure: message
                )
            case .transient(let message):
                return transientOutcome(attempts: attempts, message: message, manual: manual)
            }
        } catch {
            return transientOutcome(
                attempts: attempts, message: error.localizedDescription, manual: manual
            )
        }
    }

    private static func transientOutcome(
        attempts: Int,
        message: String,
        manual: Bool
    ) -> HealthKitFinalizationOutcome {
        let next = attempts + 1
        if manual {
            // A manual retry that fails again stays unsaved rather than re-arming auto retries.
            return HealthKitFinalizationOutcome(state: .unsaved, attempts: next, failure: message)
        }
        if next >= maxAttempts {
            return HealthKitFinalizationOutcome(state: .unsaved, attempts: next, failure: message)
        }
        return HealthKitFinalizationOutcome(state: .pending, attempts: next, failure: message)
    }
}
