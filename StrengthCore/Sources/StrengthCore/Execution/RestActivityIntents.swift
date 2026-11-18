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
        await RestLiveActivity.refresh(with: state)
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
        guard RestActivityStore.skip() != nil else { return .result() }
        await RestLiveActivity.end()
        NotificationCenter.default.post(name: .restActivityChangedExternally, object: nil)
        return .result()
    }
}

/// Updates the running activity from the persisted interval. Enumerating the activities keeps the
/// intent independent of the app's controller instance, which a background launch may not have.
@available(iOS 16.2, *)
public enum RestLiveActivity {
    public static func refresh(with state: RestActivityState) async {
        for activity in Activity<RestActivityAttributes>.activities {
            let content = ActivityContent(
                state: RestActivityAttributes.ContentState(
                    endDate: state.endsAt,
                    exerciseLabel: state.exerciseLabel
                ),
                staleDate: state.endsAt.addingTimeInterval(600)
            )
            await activity.update(content)
        }
    }

    public static func end() async {
        for activity in Activity<RestActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
#endif
