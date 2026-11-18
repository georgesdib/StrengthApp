import Foundation

/// One exercise the lifter has started and not yet ended. A superset keeps several open, so the
/// phone never infers the current exercise from whichever screen happens to be visible.
struct ActiveExercise: Codable, Equatable, Identifiable {
    let key: String
    let planItemIndex: Int?
    let exerciseId: String
    let startedAt: Date

    var id: String { key }

    static func key(planItemIndex: Int?, exerciseId: String) -> String {
        if let planItemIndex { return "item:\(planItemIndex)" }
        return "exercise:\(exerciseId)"
    }
}

/// Persisted across launches and scoped to one workout: an exercise left open when the app is
/// killed must still be endable, or its completion event would be lost.
struct ActiveExerciseSession: Codable, Equatable {
    let workoutId: String
    var exercises: [ActiveExercise]
}
