import Foundation

/// Server-adjusted time for captured actions (contract §8).
///
/// The watch derives its offset from a server timestamp and its own receipt instant, persists
/// the offset with the session, and stamps `performed_at`/`ended_at` with it. A stamp is never
/// more than a minute ahead of server-adjusted now, because the server rejects future
/// timestamps and a fast watch clock must not surface as a server error.
public struct ServerClock: Equatable, Sendable {
    /// Offsets larger than this are implausible (wrong host or a manually changed clock) and
    /// should be discarded rather than applied.
    public static let maximumPlausibleOffset: TimeInterval = 24 * 60 * 60
    /// How far ahead of server-adjusted now a stamp may sit.
    public static let futureTolerance: TimeInterval = 60

    public let offset: TimeInterval

    public init(offset: TimeInterval) {
        self.offset = offset
    }

    /// Derives the offset from a server `server_time` value and the local receipt instant.
    public init(serverTime: Date, receivedAt: Date) {
        self.offset = serverTime.timeIntervalSince(receivedAt)
    }

    /// Derives the offset from any server timestamp (for example a workout's `started_at`),
    /// so a start response is enough and no extra clock call is required.
    public init?(serverTimestamp: String, receivedAt: Date) {
        guard let parsed = Self.parse(serverTimestamp) else { return nil }
        self.init(serverTime: parsed, receivedAt: receivedAt)
    }

    /// Parses the server's ISO-8601 timestamps with or without fractional seconds.
    public static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    public var isPlausible: Bool {
        abs(offset) <= Self.maximumPlausibleOffset
    }

    public func serverNow(from local: Date) -> Date {
        local.addingTimeInterval(offset)
    }

    /// The timestamp to send for an action captured at `action`. A past action keeps its real
    /// time; a stamp skewed into the future is clamped to server-adjusted now plus a minute.
    public func stamp(action: Date, localNow: Date) -> Date {
        let adjusted = action.addingTimeInterval(offset)
        let ceiling = localNow.addingTimeInterval(offset + Self.futureTolerance)
        return min(adjusted, ceiling)
    }

    /// The wire format for captured timestamps, matching `ExecutionEvent.nowISO()`.
    public static func encodedISO(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
