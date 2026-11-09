import AudioToolbox
import Foundation
import UIKit
import UserNotifications
import StrengthCore

/// Schedules the rest-end local notification. The notification is the only way iOS can
/// alert the owner while the app is suspended; the in-app haptic/sound cover the active case.
@MainActor
final class RestNotificationManager {
    static let shared = RestNotificationManager()

    private let center = UNUserNotificationCenter.current()
    private var identifier: String?
    private var generation = UUID()
    private var authorizationRequested = false

    private init() {}

    func scheduleRestEnd(after seconds: Int) {
        guard seconds > 0 else { return }
        if let previous = identifier {
            center.removePendingNotificationRequests(withIdentifiers: [previous])
            center.removeDeliveredNotifications(withIdentifiers: [previous])
        }
        let id = "rest-end-\(UUID().uuidString.lowercased())"
        let token = UUID()
        identifier = id
        generation = token
        ensureAuthorization { [weak self] granted in
            guard let self, granted, self.generation == token else { return }
            let content = UNMutableNotificationContent()
            content.title = "Rest complete"
            content.body = "Time for your next set."
            content.sound = .default
            content.userInfo = ["kind": "rest_end"]
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: TimeInterval(max(1, seconds)),
                repeats: false
            )
            let request = UNNotificationRequest(
                identifier: id, content: content, trigger: trigger
            )
            self.center.add(request)
        }
    }

    func cancel() {
        generation = UUID()
        guard let identifier else { return }
        self.identifier = nil
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    func completeInApp() {
        guard identifier != nil else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        AudioServicesPlaySystemSound(1005)
        cancel()
    }

    private func ensureAuthorization(completion: @escaping (Bool) -> Void) {
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            Task { @MainActor in
                if settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional {
                    completion(true)
                    return
                }
                guard settings.authorizationStatus == .notDetermined,
                      !self.authorizationRequested else {
                    completion(false)
                    return
                }
                self.authorizationRequested = true
                let granted = (try? await self.center.requestAuthorization(
                    options: [.alert, .sound]
                )) ?? false
                completion(granted)
            }
        }
    }
}
