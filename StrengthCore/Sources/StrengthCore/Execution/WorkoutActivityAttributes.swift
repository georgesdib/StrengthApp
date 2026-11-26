#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// One Live Activity for a training session, whichever device currently owns the logging.
///
/// It is started from the foreground — directly when the app is visible, or by a notification tap
/// after a watch rest was reported in the background — and afterwards keeps rendering the session:
/// a rest countdown while a rest is open, and the active state between rests. ActivityKit allows
/// updating an existing activity from the background, but not starting one, so the card is
/// deliberately scoped to the workout rather than to a single rest.
public struct WorkoutActivityAttributes: ActivityAttributes {
    public enum Source: String, Codable, Hashable, Sendable {
        case phone
        case watch
    }

    public enum Phase: String, Codable, Hashable, Sendable {
        case resting
        case active
    }

    public struct ContentState: Codable, Hashable, Sendable {
        public var phase: Phase
        /// The device that owns the current rest, or the device running the session while active.
        public var source: Source
        /// The server workout this card belongs to. It is state rather than an attribute because
        /// a new session reuses the same activity with an update, never a background start.
        public var workoutId: String
        /// The system renders the countdown from this date. Nil while the session is active.
        public var endDate: Date?
        /// The movement rested after, or empty while the session is active.
        public var exerciseLabel: String

        public init(
            phase: Phase,
            source: Source,
            workoutId: String,
            endDate: Date? = nil,
            exerciseLabel: String = ""
        ) {
            self.phase = phase
            self.source = source
            self.workoutId = workoutId
            self.endDate = endDate
            self.exerciseLabel = exerciseLabel
        }
    }

    public init() {}
}
#endif
