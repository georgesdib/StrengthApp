import AudioToolbox
import Foundation
import UIKit
import UserNotifications
import StrengthCore

extension Notification.Name {
    static let restNotificationDone = Notification.Name("restNotificationDone")
}

@MainActor
final class RestNotificationManager {
    static let shared = RestNotificationManager()
    static let categoryIdentifier = "rest-end"
    static let doneActionIdentifier = "rest-end.done"

    private let center = UNUserNotificationCenter.current()
    private let defaults: UserDefaults
    private let identifierKey = "restNotificationIdentifier"
    private var generation = UUID()
    private var authorizationRequested = false

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var identifier: String? {
        get { defaults.string(forKey: identifierKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: identifierKey)
            } else {
                defaults.removeObject(forKey: identifierKey)
            }
        }
    }

    func registerCategory() {
        let done = UNNotificationAction(
            identifier: Self.doneActionIdentifier,
            title: "Done",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [done],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    func requestAuthorizationIfNeeded() {
        ensureAuthorization { _ in }
    }

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
            content.categoryIdentifier = Self.categoryIdentifier
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

    func acknowledgeDelivered() {
        guard let identifier else { return }
        self.identifier = nil
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
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

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task { @MainActor in
            RestNotificationManager.shared.registerCategory()
        }
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.actionIdentifier
        if identifier == RestNotificationManager.doneActionIdentifier
            || identifier == UNNotificationDefaultActionIdentifier {
            Task { @MainActor in
                RestNotificationManager.shared.acknowledgeDelivered()
                NotificationCenter.default.post(name: .restNotificationDone, object: nil)
            }
        }
        completionHandler()
    }
}
