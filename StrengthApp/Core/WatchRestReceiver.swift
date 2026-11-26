import Foundation
import StrengthCore
import UIKit
import os

/// Launch-time wiring for the watch-to-phone path. Called from the app delegate before the
/// SwiftUI scene exists, which is the only moment that can catch a background delivery.
@MainActor
enum WatchBackgroundBridge {
    static func start() {
        _ = WatchRestReceiver.shared
        WorkoutLiveActivityController.shared.adoptExisting()
        LiveWatchConnectivitySession.shared.activate()
    }
}

/// Receives watch user-info on the phone independently of the SwiftUI app model.
///
/// WatchConnectivity can launch the app in the background for a queued transfer, but the app's
/// normal start path runs only once its scene appears. This receiver is created at launch, so a
/// rest reported while the phone is in a pocket is still processed: an existing workout card is
/// updated, and a missing one becomes a notification the person can tap.
@MainActor
final class WatchRestReceiver {
    static let shared = WatchRestReceiver()

    private let mirror = WatchRestMirror.shared
    private let notifier = WatchRestNotifier.shared
    private let activities = WorkoutLiveActivityController.shared
    private let log = Logger(
        subsystem: "com.georgesdibpersonalteam.StrengthApp",
        category: "WorkoutActivity"
    )

    private init() {}

    @discardableResult
    func handleUserInfo(_ userInfo: [String: Any]) -> Bool {
        if let status = WatchWorkoutStatus.decode(userInfo) {
            apply(status)
            return true
        }
        // A rest-end delivery clears a notification the phone may have posted for it, even when
        // this process never saw the matching start (for example after a relaunch).
        if let snapshot = WatchRestSnapshot.decode(userInfo), snapshot.endsAt == nil {
            notifier.cancel()
        }
        return mirror.handle(userInfo)
    }

    /// The app is now visible: adopt a card left by an earlier process, consume a notification tap,
    /// and close a mirrored rest whose interval elapsed while the app was away.
    func applicationBecameActive() {
        activities.adoptExisting()
        // An intent can have updated the card while the app was suspended.
        activities.refreshFromActivity()
        notifier.clearIfExpired()
        if let pending = notifier.takePendingTap() {
            startFromTap(pending)
        }
        mirror.dismissIfElapsed()
    }

    func noteNotificationTapped() {
        notifier.noteTap()
        // A tap while the app is already active does not produce a scene-phase change. Wait for
        // the scene either way, so a response delivered during launch is not lost.
        Task { @MainActor [weak self] in
            for _ in 0..<8 where UIApplication.shared.applicationState != .active {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            self?.applicationBecameActive()
        }
    }

    private func startFromTap(_ snapshot: WatchRestSnapshot) {
        guard let endsAt = snapshot.endsAt, endsAt > Date() else {
            log.debug("Watch rest notification tapped after the interval ended; nothing to show")
            return
        }
        // A phone-owned rest is deliberate and wins over a mirrored one.
        guard !activities.isShowingPhoneRest else { return }
        let label = snapshot.exerciseLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        Task { @MainActor [weak self] in
            // The scene can still be becoming active when the tap is delivered. ActivityKit only
            // accepts the start once the app is visible, so try briefly rather than dropping it.
            for attempt in 0..<6 {
                guard let self else { return }
                let started = self.activities.startRest(
                    source: .watch,
                    endDate: endsAt,
                    exerciseLabel: label.isEmpty ? "Rest" : label,
                    workoutId: snapshot.workoutId ?? snapshot.sessionId
                )
                if started { return }
                if attempt == 5 {
                    self.log.error("Could not start the workout card after a watch notification tap")
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func apply(_ status: WatchWorkoutStatus) {
        guard status.sessionEnded, let workoutId = status.workoutId else { return }
        activities.endWorkout(workoutId)
    }
}

/// The WatchRestMirror presenter: update an existing card, start one when the app is visible,
/// and otherwise leave a notification for the person to tap.
@MainActor
final class WatchRestPresenter: WatchRestPresenting {
    static let shared = WatchRestPresenter()

    private let controller = WorkoutLiveActivityController.shared
    private let notifier = WatchRestNotifier.shared

    var isShowingPhoneRest: Bool { controller.isShowingPhoneRest }
    var isShowingWatchRest: Bool { controller.isShowingWatchRest }

    func showWatchRest(_ snapshot: WatchRestSnapshot, endDate: Date, label: String) {
        let started = controller.startRest(
            source: .watch,
            endDate: endDate,
            exerciseLabel: label,
            workoutId: snapshot.workoutId ?? snapshot.sessionId
        )
        if started {
            notifier.cancel()
        } else if UIApplication.shared.applicationState != .active {
            // With the app visible there is nothing to tap; the person can see the reason in the
            // app, and a banner would be noise.
            notifier.notify(snapshot)
        }
    }

    func endWatchRest() {
        notifier.cancel()
        controller.setActive(source: .watch)
    }
}
