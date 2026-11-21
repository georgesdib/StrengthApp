#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// Shared by the app and its widget extension so the rest Live Activity has one definition.
/// The countdown is derived from `endDate` by the system, so a suspended app still shows a
/// correct timer.
public struct RestActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var endDate: Date
        public var exerciseLabel: String

        public init(endDate: Date, exerciseLabel: String) {
            self.endDate = endDate
            self.exerciseLabel = exerciseLabel
        }
    }

    public var workoutId: String
    /// True when the rest belongs to a workout running on the Apple Watch: the countdown is
    /// mirrored from the wrist, so the phone must not offer controls it cannot honour.
    /// Optional so an activity started by an older build still decodes.
    public var watchMirrored: Bool?

    public init(workoutId: String, watchMirrored: Bool? = nil) {
        self.workoutId = workoutId
        self.watchMirrored = watchMirrored
    }
}
#endif
