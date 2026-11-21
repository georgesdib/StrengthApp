import Foundation

/// One rest state the Apple Watch reports to the iPhone, so a rest that starts on the wrist also
/// appears as a Live Activity on the phone.
///
/// The interval travels as an absolute end date: a delivery that arrives late still renders the
/// right countdown, and nothing has to tick on the phone. `launchId`/`sequence` let the receiver
/// drop a duplicate or reordered delivery without relying on WatchConnectivity ordering, and the
/// launch id restarts the sequence when the watch app relaunches.
public struct WatchRestSnapshot: Codable, Equatable, Sendable {
    /// The value carried in the `kind` field of the user-info message.
    public static let kind = "watch_rest"

    public let launchId: String
    public let sequence: Int
    public let sessionId: String
    /// nil means "the wrist has no rest running", so the phone dismisses a mirrored activity.
    public let endsAt: Date?
    public let exerciseLabel: String?
    public let workoutId: String?

    public init(
        launchId: String,
        sequence: Int,
        sessionId: String,
        endsAt: Date?,
        exerciseLabel: String? = nil,
        workoutId: String? = nil
    ) {
        self.launchId = launchId
        self.sequence = sequence
        self.sessionId = sessionId
        self.endsAt = endsAt
        self.exerciseLabel = exerciseLabel
        self.workoutId = workoutId
    }

    /// The queued WatchConnectivity message. A user-info transfer survives an unreachable phone
    /// and wakes the app in the background, which `sendMessage` cannot do.
    public var message: [String: Any]? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return ["kind": Self.kind, "payload": json]
    }

    public static func decode(_ message: [String: Any]) -> WatchRestSnapshot? {
        guard (message["kind"] as? String) == kind,
              let json = message["payload"] as? String,
              let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WatchRestSnapshot.self, from: data)
    }
}

/// What the phone does with one delivery.
public enum WatchRestMirrorPolicy {
    public enum Action: Equatable, Sendable {
        /// Start or refresh the mirrored Live Activity.
        case show(endDate: Date, label: String)
        /// Close the mirrored Live Activity.
        case dismiss
        /// Nothing to do: a duplicate, a phone-owned rest, or a rest that is already over.
        case ignore
    }

    public struct Decision: Equatable, Sendable {
        public let action: Action
        /// True when this delivery is the newest one and should be remembered as such.
        public let recordSequence: Bool

        public init(action: Action, recordSequence: Bool) {
            self.action = action
            self.recordSequence = recordSequence
        }
    }

    /// - Parameters:
    ///   - snapshot: the delivery.
    ///   - lastLaunchId: the launch id of the last accepted delivery.
    ///   - lastSequence: the sequence of the last accepted delivery for that launch.
    ///   - phoneOwnsActivity: true when a rest started on the phone is showing.
    ///   - watchActivityShowing: true when this phone is already mirroring a watch rest.
    ///   - now: the clock, injected for tests.
    public static func decide(
        _ snapshot: WatchRestSnapshot,
        lastLaunchId: String?,
        lastSequence: Int,
        phoneOwnsActivity: Bool,
        watchActivityShowing: Bool,
        now: Date
    ) -> Decision {
        // A different launch restarts the counter, so a relaunched watch is never "stale".
        if snapshot.launchId == lastLaunchId, snapshot.sequence <= lastSequence {
            return Decision(action: .ignore, recordSequence: false)
        }
        // A rest started on the phone wins: the wrist has no business replacing it. The delivery
        // is not recorded, so the wrist's next transition is still evaluated on its own.
        if phoneOwnsActivity {
            return Decision(action: .ignore, recordSequence: false)
        }
        guard let endsAt = snapshot.endsAt, endsAt > now else {
            // No rest, or one that ended before the delivery landed. Close only what we own.
            return Decision(
                action: watchActivityShowing ? .dismiss : .ignore,
                recordSequence: true
            )
        }
        let label = snapshot.exerciseLabel.flatMap { $0.isEmpty ? nil : $0 } ?? "Rest"
        return Decision(action: .show(endDate: endsAt, label: label), recordSequence: true)
    }
}
