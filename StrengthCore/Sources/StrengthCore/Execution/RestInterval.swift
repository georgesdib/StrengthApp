import Foundation

public enum RestOutcome: String, Codable, Sendable {
    case completed
    case skipped
}

/// A rest period stored as an end date rather than a countdown (contract §11.4), so it
/// survives a backgrounded app, a suspension or a relaunch without depending on the UI.
public struct RestInterval: Codable, Equatable, Sendable {
    public let startedAt: Date
    public let prescribedSeconds: Int
    public private(set) var endsAt: Date
    public private(set) var addedSeconds: Int
    public var endedAt: Date?
    public var outcome: RestOutcome?
    /// The plan item this rest followed, so the telemetry event can stay attributable.
    public var planItemIndex: Int?

    public init(
        startedAt: Date,
        prescribedSeconds: Int,
        endsAt: Date? = nil,
        planItemIndex: Int? = nil
    ) {
        self.startedAt = startedAt
        self.prescribedSeconds = max(0, prescribedSeconds)
        self.endsAt = endsAt ?? startedAt.addingTimeInterval(TimeInterval(max(0, prescribedSeconds)))
        self.addedSeconds = 0
        self.endedAt = nil
        self.outcome = nil
        self.planItemIndex = planItemIndex
    }

    public var prescribedEndsAt: Date {
        startedAt.addingTimeInterval(TimeInterval(prescribedSeconds))
    }

    public func remaining(at date: Date) -> TimeInterval {
        max(0, endsAt.timeIntervalSince(date))
    }

    public func isComplete(at date: Date) -> Bool {
        date >= endsAt
    }

    public var isOpen: Bool {
        endedAt == nil
    }

    /// Extends the rest and records the added time so the observation stays truthful.
    @discardableResult
    public mutating func extend(by seconds: Int) -> Date {
        let added = max(0, seconds)
        guard added > 0 else { return endsAt }
        addedSeconds += added
        endsAt = endsAt.addingTimeInterval(TimeInterval(added))
        endedAt = nil
        outcome = nil
        return endsAt
    }

    /// Shortens the open rest, never below its own start. No server event is emitted: the
    /// interval that the eventual completion records is simply shorter, which is the truth.
    public mutating func shorten(by seconds: Int, at date: Date) -> Date {
        let cut = max(0, seconds)
        guard cut > 0 else { return endsAt }
        // Never rewrite history: the shortened end stays inside [start, now, old end].
        endsAt = max(max(startedAt, date), endsAt.addingTimeInterval(-TimeInterval(cut)))
        return endsAt
    }

    /// Closes the rest and returns the observed interval, or nil when it was already closed.
    @discardableResult
    public mutating func finish(at date: Date, outcome: RestOutcome) -> RestInterval? {
        guard endedAt == nil else { return nil }
        endedAt = date
        self.outcome = outcome
        return self
    }

    public var actualSeconds: TimeInterval? {
        guard let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }
}
