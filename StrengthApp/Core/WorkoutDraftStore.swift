import Combine
import Foundation

/// Form state for an exercise's next set, kept at the workout-screen level so pushing to the
/// exercise screen and returning does not discard an unfinished entry.
@MainActor
final class WorkoutDraftStore: ObservableObject {
    struct Draft: Equatable {
        var loadText = ""
        var repsText = ""
        var rirText = ""
        var velocityText = ""
        var repVelocityText = ""
        var showingRepVelocity = false
        var planSetIndex: Int?
    }

    @Published var drafts: [String: Draft] = [:]

    func key(exerciseId: String, planIndex: Int?) -> String {
        "\(exerciseId)|\(planIndex.map(String.init) ?? "other")"
    }

    func draft(for key: String) -> Draft? { drafts[key] }

    func set(_ draft: Draft, for key: String) { drafts[key] = draft }
}
