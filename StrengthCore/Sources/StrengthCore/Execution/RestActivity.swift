import Foundation

/// The rest interval as persisted across app launches.
///
/// The key and JSON shape are the ones `RestTimerModel` has always written, so an interval that
/// is running when the app is updated still restores. The Live Activity intents read and write
/// this same record, which keeps the persisted interval — not the activity — the single source
/// of truth: the activity only renders it.
public struct RestActivityState: Codable, Equatable, Sendable {
    public var workoutId: String?
    public var startedAt: Date
    public var prescribedSeconds: Int
    public var addedSeconds: Int
    public var planItemIndex: Int?
    public var exerciseId: String?

    public init(
        workoutId: String?,
        startedAt: Date,
        prescribedSeconds: Int,
        addedSeconds: Int = 0,
        planItemIndex: Int? = nil,
        exerciseId: String? = nil
    ) {
        self.workoutId = workoutId
        self.startedAt = startedAt
        self.prescribedSeconds = prescribedSeconds
        self.addedSeconds = addedSeconds
        self.planItemIndex = planItemIndex
        self.exerciseId = exerciseId
    }

    public var endsAt: Date {
        startedAt.addingTimeInterval(TimeInterval(prescribedSeconds + addedSeconds))
    }

    public func isComplete(at date: Date) -> Bool {
        date >= endsAt
    }

    /// A readable movement name for the Lock Screen and the Dynamic Island.
    public var exerciseLabel: String {
        guard let exerciseId, !exerciseId.isEmpty else { return "Rest" }
        return exerciseId
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

/// A rest that ended somewhere the app was not: the Live Activity's Skip, or an extension that
/// arrived while the app was suspended. The app consumes it once to record the telemetry.
public struct RestActivityCompletion: Codable, Equatable, Sendable {
    public let workoutId: String?
    public let startedAt: Date
    public let endedAt: Date
    public let prescribedSeconds: Int
    public let addedSeconds: Int
    public let planItemIndex: Int?
    public let exerciseId: String?
    public let outcome: String

    public init(
        workoutId: String?,
        startedAt: Date,
        endedAt: Date,
        prescribedSeconds: Int,
        addedSeconds: Int,
        planItemIndex: Int?,
        exerciseId: String?,
        outcome: String
    ) {
        self.workoutId = workoutId
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.prescribedSeconds = prescribedSeconds
        self.addedSeconds = addedSeconds
        self.planItemIndex = planItemIndex
        self.exerciseId = exerciseId
        self.outcome = outcome
    }
}

extension Notification.Name {
    /// Posted after a Live Activity intent changed the persisted interval, so a running app can
    /// apply it without waiting for the next activation.
    public static let restActivityChangedExternally = Notification.Name("restActivityChangedExternally")
}

/// Reads and writes the persisted rest interval. Every mutation is a read-modify-write against
/// `UserDefaults`, so the app and an intent running in the same process cannot disagree for long.
public enum RestActivityStore {
    public static let stateKey = "restTimer.state"
    public static let completionKey = "restTimer.externalCompletion"
    public static let extensionKey = "restTimer.externalExtension"

    public static func load(from defaults: UserDefaults = .standard) -> RestActivityState? {
        guard let data = defaults.data(forKey: stateKey) else { return nil }
        return try? JSONDecoder().decode(RestActivityState.self, from: data)
    }

    public static func save(_ state: RestActivityState, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: stateKey)
    }

    public static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: stateKey)
    }

    /// Adds time to the open interval. Returns nil when nothing is running, or when the rest has
    /// already elapsed — the in-app +15 s button is hidden in that state, so the activity matches.
    @discardableResult
    public static func extend(
        by seconds: Int,
        now: Date = Date(),
        in defaults: UserDefaults = .standard
    ) -> RestActivityState? {
        guard seconds > 0, var state = load(from: defaults), !state.isComplete(at: now) else {
            return nil
        }
        state.addedSeconds += seconds
        save(state, to: defaults)
        let pending = (defaults.integer(forKey: extensionKey)) + seconds
        defaults.set(pending, forKey: extensionKey)
        return state
    }

    /// Ends the interval early and leaves the completion for the app to record. Returns nil when
    /// there is nothing to skip.
    @discardableResult
    public static func skip(
        at date: Date = Date(),
        in defaults: UserDefaults = .standard
    ) -> RestActivityCompletion? {
        guard let state = load(from: defaults) else { return nil }
        let completion = RestActivityCompletion(
            workoutId: state.workoutId,
            startedAt: state.startedAt,
            endedAt: date,
            prescribedSeconds: state.prescribedSeconds,
            addedSeconds: state.addedSeconds,
            planItemIndex: state.planItemIndex,
            exerciseId: state.exerciseId,
            outcome: "skipped"
        )
        if let data = try? JSONEncoder().encode(completion) {
            defaults.set(data, forKey: completionKey)
        }
        clear(from: defaults)
        return completion
    }

    /// Consumes the completion exactly once.
    public static func takeCompletion(from defaults: UserDefaults = .standard) -> RestActivityCompletion? {
        guard let data = defaults.data(forKey: completionKey) else { return nil }
        defaults.removeObject(forKey: completionKey)
        return try? JSONDecoder().decode(RestActivityCompletion.self, from: data)
    }

    /// Consumes the time added from the activity so the app can record one `rest_extended`.
    public static func takeExtension(from defaults: UserDefaults = .standard) -> Int? {
        let seconds = defaults.integer(forKey: extensionKey)
        guard seconds > 0 else { return nil }
        defaults.removeObject(forKey: extensionKey)
        return seconds
    }
}
