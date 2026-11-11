import Foundation

public enum WatchLivenessStatus: Equatable, Sendable {
    case idle
    case running
    case foregroundOnly(reason: String?)
}

/// Contract §11.2: a session without a running HealthKit workout is foreground-only, and the UI
/// must say so. Liveness is claimed only after the anchor reports that it actually started.
public struct WatchLivenessPolicy: Equatable, Sendable {
    public static let bannerText = "Logging may stop when the screen locks."

    public private(set) var status: WatchLivenessStatus = .idle

    public init() {}

    public var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    public var isForegroundOnly: Bool {
        if case .foregroundOnly = status { return true }
        return false
    }

    /// The sentence the Set screen shows; nil while the session is properly anchored.
    public var banner: String? {
        isForegroundOnly ? Self.bannerText : nil
    }

    public var detail: String? {
        if case .foregroundOnly(let reason) = status { return reason }
        return nil
    }

    public mutating func started() {
        status = .running
    }

    public mutating func authorizationUnavailable() {
        status = .foregroundOnly(
            reason: "Health access is off, so the watch cannot keep this session alive."
        )
    }

    public mutating func failed(_ reason: String?) {
        status = .foregroundOnly(
            reason: reason ?? "The watch could not keep a workout running."
        )
    }

    public mutating func reset() {
        status = .idle
    }
}
