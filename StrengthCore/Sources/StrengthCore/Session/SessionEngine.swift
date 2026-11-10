import Foundation

/// Pure state for one workout-execution operation. The app remains the published adapter; this
/// value type is the reducer's input and output.
public struct SessionState {
    public var activeWorkout: WorkoutDetail?
    public var isSaving: Bool
    public var mutationError: String?
    public var mutationFailureAmbiguous: Bool

    public init(
        activeWorkout: WorkoutDetail? = nil,
        isSaving: Bool = false,
        mutationError: String? = nil,
        mutationFailureAmbiguous: Bool = false
    ) {
        self.activeWorkout = activeWorkout
        self.isSaving = isSaving
        self.mutationError = mutationError
        self.mutationFailureAmbiguous = mutationFailureAmbiguous
    }
}

public enum SessionEvent {
    case operationBegan
    case operationSucceeded(WorkoutDetail)
    case operationQueued(WorkoutDetail?)
    case operationFailed(message: String, ambiguous: Bool)
    case operationEnded
    case activeWorkoutChanged(WorkoutDetail?)
    case mutationErrorCleared
}

public enum SessionEffect: Equatable {
    case persistActiveWorkout
    case refreshPendingMutations
}

/// One operation's transition. Side effects are declared here and executed by the app adapter.
public enum SessionReducer {
    public static func reduce(
        _ state: SessionState,
        _ event: SessionEvent
    ) -> (SessionState, [SessionEffect]) {
        var next = state
        switch event {
        case .operationBegan:
            next.isSaving = true
            next.mutationFailureAmbiguous = false
            return (next, [])
        case .operationSucceeded(let workout):
            next.activeWorkout = workout
            next.isSaving = false
            next.mutationError = nil
            next.mutationFailureAmbiguous = false
            return (next, [.refreshPendingMutations])
        case .operationQueued(let workout):
            next.activeWorkout = workout
            next.isSaving = false
            next.mutationError = nil
            next.mutationFailureAmbiguous = false
            return (next, [.persistActiveWorkout, .refreshPendingMutations])
        case .operationFailed(let message, let ambiguous):
            next.isSaving = false
            next.mutationError = message
            next.mutationFailureAmbiguous = ambiguous
            return (next, [.refreshPendingMutations])
        case .operationEnded:
            next.isSaving = false
            return (next, [.refreshPendingMutations])
        case .activeWorkoutChanged(let workout):
            next.activeWorkout = workout
            return (next, [.persistActiveWorkout])
        case .mutationErrorCleared:
            next.mutationError = nil
            next.mutationFailureAmbiguous = false
            return (next, [])
        }
    }
}
