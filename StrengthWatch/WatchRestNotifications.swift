import Foundation
import UserNotifications

/// Schedules a local notification for the end of a rest interval, so the wrist is told even
/// when the app is not on screen. Best-effort: a denied permission never blocks a set.
@MainActor
final class WatchRestNotifications {
    static let shared = WatchRestNotifications()

    private let center = UNUserNotificationCenter.current()
    private static let identifier = "watch-rest-complete"
    private var requested = false

    func requestAuthorizationIfNeeded() async {
        guard !requested else { return }
        requested = true
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func schedule(at date: Date) {
        cancel()
        guard date.timeIntervalSinceNow > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Rest complete"
        content.body = "Start your next set."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, date.timeIntervalSinceNow),
            repeats: false
        )
        center.add(UNNotificationRequest(
            identifier: Self.identifier,
            content: content,
            trigger: trigger
        ))
    }

    func cancel() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
    }
}
