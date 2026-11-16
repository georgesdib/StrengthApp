import Foundation
import UserNotifications

/// The authorization seam, so scheduling is testable without a real notification centre.
@MainActor
protocol NotificationAuthorizing: AnyObject {
    func status() async -> UNAuthorizationStatus
    func ensureAuthorized() async -> Bool
}

/// One authorization owner for every notification surface, so enabling a reminder and starting a
/// rest timer cannot prompt twice, and neither prompts at launch.
@MainActor
final class NotificationAuthorizer: NotificationAuthorizing {
    static let shared = NotificationAuthorizer()

    private let center: UNUserNotificationCenter
    private var requested = false

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func status() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func ensureAuthorized() async -> Bool {
        await ensureAuthorized(options: [.alert, .sound])
    }

    /// Prompts at most once per process. Never called from a plain refresh: only from an explicit
    /// owner action such as enabling the daily reminder or starting a rest timer.
    func ensureAuthorized(options: UNAuthorizationOptions) async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            guard !requested else { return false }
            requested = true
            return (try? await center.requestAuthorization(options: options)) ?? false
        default:
            return false
        }
    }
}
