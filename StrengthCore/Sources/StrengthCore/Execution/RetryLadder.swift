import Foundation

/// The offline flush retry schedule (contract §10.7): 5s, 15s, 60s, then every 5 minutes,
/// with a 15-minute retry window, reset by a success.
///
/// The window is measured from the first failure of the current burst. Once a scheduled
/// attempt would fall outside it, `failed(at:)` returns nil and the caller stops scheduling:
/// only a foreground, a network-path change or an explicit retry may start a new burst.
public struct RetryLadder: Equatable, Sendable {
    public static let defaultDelays: [TimeInterval] = [5, 15, 60, 300]
    public static let defaultWindow: TimeInterval = 15 * 60

    public let delays: [TimeInterval]
    public let window: TimeInterval

    public private(set) var attempt: Int
    public private(set) var windowStartedAt: Date?

    public init(
        delays: [TimeInterval] = RetryLadder.defaultDelays,
        window: TimeInterval = RetryLadder.defaultWindow
    ) {
        self.delays = delays.isEmpty ? Self.defaultDelays : delays
        self.window = window
        self.attempt = 0
        self.windowStartedAt = nil
    }

    /// The wait before the given one-based attempt. The last delay repeats.
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        return delays[min(attempt - 1, delays.count - 1)]
    }

    /// True once the current burst has spent its 15-minute window.
    public func isExhausted(at date: Date) -> Bool {
        guard let windowStartedAt else { return false }
        return date.timeIntervalSince(windowStartedAt) >= window
    }

    /// Records a failure and returns when the next attempt is due, or nil once the 15-minute
    /// window is spent and automatic retries must stop.
    ///
    /// A wait that would run past the window is clamped to the window's end, so the final
    /// attempt happens at 15 minutes rather than being skipped altogether.
    @discardableResult
    public mutating func failed(at date: Date) -> Date? {
        if windowStartedAt == nil {
            windowStartedAt = date
        }
        guard let windowStartedAt else { return nil }
        let windowEnd = windowStartedAt.addingTimeInterval(window)
        guard date < windowEnd else { return nil }
        attempt += 1
        return min(date.addingTimeInterval(delay(forAttempt: attempt)), windowEnd)
    }

    /// Acknowledged work resets the ladder completely.
    public mutating func succeeded() {
        attempt = 0
        windowStartedAt = nil
    }

    /// A foreground or network-path-change trigger starts a fresh window after exhaustion.
    /// Returns the moment the retry should run, or nil when the current burst still has time.
    @discardableResult
    public mutating func restartWindow(at date: Date) -> Date? {
        guard isExhausted(at: date) else { return nil }
        attempt = 0
        windowStartedAt = date
        return date
    }
}
