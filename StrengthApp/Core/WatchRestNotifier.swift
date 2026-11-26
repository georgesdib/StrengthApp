import Foundation
import StrengthCore
import UserNotifications
import os

/// The phone-side fallback for a watch rest that arrives while the app cannot start a Live
/// Activity. ActivityKit refuses a background start, so the phone posts a notification instead;
/// tapping it brings the app to the foreground, where the start is allowed.
///
/// The latest rest is persisted with the notification so a cold launch from the tap can still
/// start the card with the original absolute end date.
@MainActor
final class WatchRestNotifier {
    static let shared = WatchRestNotifier()
    static let categoryIdentifier = "watch-rest"
    static let showActionIdentifier = "watch-rest.show"
    private static let requestIdentifier = "watch-rest"
    private static let pendingKey = "watchRest.pendingMessage"

    private let center = UNUserNotificationCenter.current()
    private let defaults: UserDefaults
    private let authorizer = NotificationAuthorizer.shared
    private let log = Logger(
        subsystem: "com.georgesdibpersonalteam.StrengthApp",
        category: "WorkoutActivity"
    )
    /// Set when the person taps the notification, and consumed when the app is foreground.
    private var tapped = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Posts the rest alert, replacing any earlier one so the Lock Screen never stacks a rest that
    /// has already been superseded. Notification authorization is never requested here: this runs
    /// in the background, and the explicit watch-pairing prompt owns the first request.
    func notify(_ snapshot: WatchRestSnapshot) {
        guard let endsAt = snapshot.endsAt, endsAt > Date() else { return }
        savePending(snapshot)
        let content = UNMutableNotificationContent()
        content.title = "Rest on Apple Watch"
        content.body = Self.body(for: snapshot, endsAt: endsAt)
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = Self.categoryIdentifier
        content.userInfo = ["kind": "watch_rest"]
        center.removePendingNotificationRequests(withIdentifiers: [Self.requestIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.requestIdentifier])
        let request = UNNotificationRequest(
            identifier: Self.requestIdentifier,
            content: content,
            trigger: nil
        )
        Task { @MainActor [authorizer, center, log] in
            let status = await authorizer.status()
            switch status {
            case .authorized, .provisional, .ephemeral:
                do {
                    try await center.add(request)
                } catch {
                    log.error("Could not post the watch rest notification: \(error.localizedDescription, privacy: .public)")
                }
            default:
                log.error("Watch rest notification skipped: notifications are not authorized")
            }
        }
    }

    func cancel() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.requestIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.requestIdentifier])
        defaults.removeObject(forKey: Self.pendingKey)
    }

    /// Drops a stored rest whose interval has already elapsed, so an old notification prompt
    /// cannot be tapped into a countdown that has no time left.
    func clearIfExpired(now: Date = Date()) {
        guard let snapshot = loadPending(), let endsAt = snapshot.endsAt, endsAt <= now else {
            return
        }
        cancel()
    }

    func noteTap() {
        tapped = true
        center.removeDeliveredNotifications(withIdentifiers: [Self.requestIdentifier])
    }

    /// Consumes the tap exactly once, returning the rest it referred to.
    func takePendingTap() -> WatchRestSnapshot? {
        guard tapped else { return nil }
        tapped = false
        let snapshot = loadPending()
        defaults.removeObject(forKey: Self.pendingKey)
        return snapshot
    }

    private func savePending(_ snapshot: WatchRestSnapshot) {
        guard let message = snapshot.message else { return }
        defaults.set(message, forKey: Self.pendingKey)
    }

    private func loadPending() -> WatchRestSnapshot? {
        guard let message = defaults.dictionary(forKey: Self.pendingKey) else { return nil }
        return WatchRestSnapshot.decode(message)
    }

    private static func body(for snapshot: WatchRestSnapshot, endsAt: Date) -> String {
        let trimmed = snapshot.exerciseLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = trimmed.isEmpty ? "Rest" : trimmed
        let remaining = max(0, Int(endsAt.timeIntervalSinceNow.rounded(.up)))
        let clock = String(format: "%d:%02d", remaining / 60, remaining % 60)
        return name + " · " + clock + " remaining · Tap to show the countdown"
    }
}
