import Foundation
import UserNotifications
import StrengthCore

/// The notification centre seam, so scheduling is testable without a real centre.
@MainActor
protocol NudgeCenter: AnyObject {
    func add(_ request: UNNotificationRequest) async
    func removePending(withIdentifiers identifiers: [String])
    func pendingIdentifiers() async -> [String]
}

@MainActor
final class LiveNudgeCenter: NudgeCenter {
    private let center = UNUserNotificationCenter.current()

    func add(_ request: UNNotificationRequest) async {
        try? await center.add(request)
    }

    func removePending(withIdentifiers identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }
}

/// Schedules the daily reminder.
///
/// A local notification's text is frozen when it is scheduled, so the app renders the message while
/// it is in the foreground and schedules the next occurrences. Rebuilding is idempotent: the horizon
/// is only replaced when the rendered schedule differs, which is why re-arming on every refresh
/// cannot duplicate a notification.
@MainActor
final class NudgeScheduler {
    static let shared = NudgeScheduler()

    static let categoryIdentifier = "nudge"
    static let readinessActionIdentifier = "nudge.readiness"
    static let identifierPrefix = "nudge."
    static let horizon = 7

    private static let lastCompletedKey = "nudge.lastSessionCompletedAt"
    private static let signatureKey = "nudge.scheduleSignature"

    private let center: any NudgeCenter
    private let defaults: UserDefaults
    private let generator: any NudgeGenerating
    private let authorizer: any NotificationAuthorizing
    private let calendar: Calendar

    // Defaults are built in the body: a default argument is evaluated outside the actor, which
    // cannot touch the notification centre or the shared authorizer.
    init(
        center: (any NudgeCenter)? = nil,
        defaults: UserDefaults = .standard,
        generator: (any NudgeGenerating)? = nil,
        authorizer: (any NotificationAuthorizing)? = nil,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.center = center ?? LiveNudgeCenter()
        self.defaults = defaults
        self.generator = generator ?? FoundationNudgeGenerator()
        self.authorizer = authorizer ?? NotificationAuthorizer.shared
        self.calendar = calendar
    }

    var isAuthorized: Bool {
        get async {
            let status = await authorizer.status()
            return status == .authorized || status == .provisional || status == .ephemeral
        }
    }

    func requestAuthorization() async -> Bool {
        await authorizer.ensureAuthorized()
    }

    /// Rebuilds the horizon when the time, the day set or the rendered message changed.
    func refresh(enabled: Bool, hour: Int, minute: Int, facts: NudgeFacts?, now: Date = Date()) async {
        guard enabled, await isAuthorized else {
            await clear()
            return
        }
        let occurrences = NudgeSchedule.occurrences(
            hour: hour, minute: minute, count: Self.horizon + 3, now: now, calendar: calendar
        )
        var planned: [(date: Date, message: NudgeMessage)] = []
        for date in occurrences where planned.count < Self.horizon {
            if isSuppressed(date, facts: facts, now: now) { continue }
            let message: NudgeMessage
            if planned.isEmpty, let facts, calendar.isDate(date, inSameDayAs: now) {
                message = await NudgeComposer.compose(facts: facts, generator: generator)
            } else {
                // Any other day would be quoting facts that are already stale by then.
                message = NudgeCopy.generic()
            }
            planned.append((date, message))
        }

        let signature = signature(hour: hour, minute: minute, planned: planned)
        guard signature != defaults.string(forKey: Self.signatureKey) else { return }

        let existing = await center.pendingIdentifiers().filter { $0.hasPrefix(Self.identifierPrefix) }
        center.removePending(withIdentifiers: existing)
        for entry in planned {
            await center.add(request(for: entry.date, message: entry.message))
        }
        defaults.set(signature, forKey: Self.signatureKey)
    }

    /// A completed session silences that day, so a workout at 17:00 does not get nudged at 19:00.
    func recordSessionCompleted(at date: Date = Date()) {
        defaults.set(date, forKey: Self.lastCompletedKey)
    }

    var lastSessionCompletedAt: Date? {
        defaults.object(forKey: Self.lastCompletedKey) as? Date
    }

    func clear() async {
        let existing = await center.pendingIdentifiers().filter { $0.hasPrefix(Self.identifierPrefix) }
        if !existing.isEmpty {
            center.removePending(withIdentifiers: existing)
        }
        defaults.removeObject(forKey: Self.signatureKey)
    }

    // MARK: - Internals

    private func isSuppressed(_ date: Date, facts: NudgeFacts?, now: Date) -> Bool {
        if let facts, facts.sessionInProgress, calendar.isDate(date, inSameDayAs: now) {
            return true
        }
        guard let last = lastSessionCompletedAt else { return false }
        return calendar.isDate(date, inSameDayAs: last)
    }

    private func signature(
        hour: Int,
        minute: Int,
        planned: [(date: Date, message: NudgeMessage)]
    ) -> String {
        var parts = ["\(hour):\(minute)"]
        for entry in planned {
            parts.append(dayKey(entry.date) + "|" + entry.message.title + "|" + entry.message.body)
        }
        return parts.joined(separator: "\n")
    }

    private func request(for date: Date, message: NudgeMessage) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = ["kind": "nudge"]
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute], from: date
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        return UNNotificationRequest(
            identifier: Self.identifierPrefix + dayKey(date),
            content: content,
            trigger: trigger
        )
    }

    private func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
        )
    }
}

/// Carries a tap from the notification delegate to the model, including a cold launch where the
/// delegate runs before the SwiftUI hierarchy exists.
@MainActor
final class NudgeRouter {
    static let shared = NudgeRouter()
    static let tapped = Notification.Name("nudgeTapped")

    private var pending = false

    func requestReadiness() {
        pending = true
        NotificationCenter.default.post(name: Self.tapped, object: nil)
    }

    func consume() -> Bool {
        defer { pending = false }
        return pending
    }
}
