#if os(iOS)
import ActivityKit
import AppIntents
import Foundation

/// The two controls the rest Live Activity offers. They are `LiveActivityIntent`s, so the system
/// runs them in the app's process without opening the app or unlocking the phone: the interval is
/// extended or closed at the tap, and the widget re-renders from the persisted end date.
@available(iOS 17.0, *)
public struct ExtendRestIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Add 15 seconds of rest"
    public static var isDiscoverable: Bool = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        guard let state = RestActivityStore.extend(by: 15) else { return .result() }
        await WorkoutLiveActivity.refresh(with: state)
        NotificationCenter.default.post(name: .restActivityChangedExternally, object: nil)
        return .result()
    }
}

@available(iOS 17.0, *)
public struct SkipRestIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Skip rest"
    public static var isDiscoverable: Bool = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        guard let completion = RestActivityStore.skip() else { return .result() }
        // The workout is still running, so the card moves to its active state instead of ending.
        await WorkoutLiveActivity.setActive(workoutId: completion.workoutId)
        NotificationCenter.default.post(name: .restActivityChangedExternally, object: nil)
        return .result()
    }
}

/// Starts the workout card from Control Center or the Action button without opening the app.
///
/// It only acts when the phone already has an active workout in its persisted capture: the card
/// needs a real workout id, and inventing one would leave a card that cannot be matched to a
/// session. A tap with no active workout does nothing.
@available(iOS 17.0, *)
public struct StartWorkoutCardIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Show workout card"
    public static var isDiscoverable: Bool = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              Activity<WorkoutActivityAttributes>.activities.isEmpty,
              let workout = (try? OfflineCaptureStore().load())?.activeWorkout,
              !workout.workoutId.isEmpty else {
            return .result()
        }
        let state = WorkoutActivityAttributes.ContentState(
            phase: .active,
            source: Self.source(for: workout),
            workoutId: workout.workoutId
        )
        let content = ActivityContent(
            state: state,
            staleDate: Date().addingTimeInterval(8 * 60 * 60)
        )
        _ = try? Activity.request(attributes: WorkoutActivityAttributes(), content: content)
        return .result()
    }

    /// Ownership is provenance after S5, so the workout's owner tells the card which device to
    /// name. The watch link is the same on-device metadata the app writes.
    private static func source(
        for workout: WorkoutDetail
    ) -> WorkoutActivityAttributes.Source {
        guard let watchDevice = watchDeviceID(),
              workout.ownerDeviceId == watchDevice else { return .phone }
        return .watch
    }

    private static func watchDeviceID() -> String? {
        struct Link: Decodable {
            let deviceID: String
            let revoked: Bool?
        }
        guard let data = UserDefaults.standard.data(forKey: SharedDefaultsKeys.watchLink),
              let link = try? JSONDecoder().decode(Link.self, from: data),
              link.revoked != true else { return nil }
        return link.deviceID
    }
}

/// Updates the running activity from the persisted interval. Enumerating the activities keeps the
/// intent independent of the app's controller instance, which a background launch may not have.
@available(iOS 16.2, *)
public enum WorkoutLiveActivity {
    public static func refresh(with state: RestActivityState) async {
        for activity in Activity<WorkoutActivityAttributes>.activities {
            // Controls only ever belong to a phone-owned rest; do not rewrite a watch rest.
            guard activity.content.state.source == .phone else { continue }
            let content = ActivityContent(
                state: WorkoutActivityAttributes.ContentState(
                    phase: .resting,
                    source: .phone,
                    workoutId: state.workoutId ?? activity.content.state.workoutId,
                    endDate: state.endsAt,
                    exerciseLabel: state.exerciseLabel
                ),
                staleDate: state.endsAt.addingTimeInterval(600)
            )
            await activity.update(content)
        }
    }

    /// Moves a phone-owned rest card to the workout's active state. The rest was ended by the
    /// activity's Skip button; the app records the completion on its next activation.
    public static func setActive(workoutId: String?) async {
        for activity in Activity<WorkoutActivityAttributes>.activities {
            guard activity.content.state.source == .phone,
                  activity.content.state.phase == .resting else { continue }
            let content = ActivityContent(
                state: WorkoutActivityAttributes.ContentState(
                    phase: .active,
                    source: .phone,
                    workoutId: workoutId ?? activity.content.state.workoutId
                ),
                staleDate: Date().addingTimeInterval(8 * 60 * 60)
            )
            await activity.update(content)
        }
    }

    public static func end() async {
        for activity in Activity<WorkoutActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
#endif
