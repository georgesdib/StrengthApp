import ActivityKit
import Foundation
import StrengthCore

/// Owns the single rest Live Activity. The system renders the countdown from `endDate`, so the
/// app does not need to tick while the phone is locked or suspended.
@MainActor
final class RestLiveActivityController {
    static let shared = RestLiveActivityController()

    private var activity: Activity<RestActivityAttributes>?

    func start(endDate: Date, exerciseId: String?, workoutId: String?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end()
        let attributes = RestActivityAttributes(workoutId: workoutId ?? "")
        let state = RestActivityAttributes.ContentState(
            endDate: endDate,
            exerciseLabel: Self.label(exerciseId)
        )
        activity = try? Activity.request(
            attributes: attributes,
            content: ActivityContent(state: state, staleDate: endDate.addingTimeInterval(600))
        )
    }

    func update(endDate: Date, exerciseId: String?) {
        guard let activity else { return }
        let state = RestActivityAttributes.ContentState(
            endDate: endDate,
            exerciseLabel: Self.label(exerciseId)
        )
        Task { [activity] in
            await activity.update(
                ActivityContent(state: state, staleDate: endDate.addingTimeInterval(600))
            )
        }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { [activity] in
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private static func label(_ exerciseId: String?) -> String {
        guard let exerciseId, !exerciseId.isEmpty else { return "Rest" }
        return exerciseId
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
