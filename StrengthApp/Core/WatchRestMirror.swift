import Foundation
import StrengthCore

/// The phone's side of a rest mirrored from the Apple Watch.
///
/// WatchConnectivity delivers user info on a queued channel that survives an unreachable phone
/// and wakes this app in the background, which is exactly what a rest interval needs: the watch
/// owns the session and the phone only renders it.
@MainActor
protocol RestActivityPresenting: AnyObject {
    var isShowingPhoneRest: Bool { get }
    var isShowingWatchRest: Bool { get }
    func showWatchRest(endDate: Date, exerciseLabel: String, workoutId: String)
    func endWatchRest()
}

@MainActor
final class WatchRestMirror {
    static let shared = WatchRestMirror()

    private let presenter: RestActivityPresenting
    private var lastLaunchId: String?
    private var lastSequence = 0
    /// The end of the interval currently mirrored, so the phone can close it when it wakes up
    /// after the rest has already finished. The system renders the countdown; this only decides
    /// when the card goes away.
    private var scheduledEnd: Date?
    private var endTask: Task<Void, Never>?
    /// What the presenter was last asked for. `Activity.request` completes asynchronously, so a
    /// rest that ends in that window must still close the card it just asked for.
    private var watchRestRequested = false

    /// The presenter is resolved inside the initialiser: a default argument naming a main-actor
    /// singleton would be evaluated outside the actor.
    init(presenter: RestActivityPresenting? = nil) {
        self.presenter = presenter ?? RestLiveActivityController.shared
    }

    /// Handles one user-info message. Returns true when it was a rest delivery, so the caller can
    /// keep the relay and profile channels separate.
    @discardableResult
    func handle(_ message: [String: Any], now: Date = Date()) -> Bool {
        guard let snapshot = WatchRestSnapshot.decode(message) else { return false }
        apply(snapshot, now: now)
        return true
    }

    func apply(_ snapshot: WatchRestSnapshot, now: Date = Date()) {
        let decision = WatchRestMirrorPolicy.decide(
            snapshot,
            lastLaunchId: lastLaunchId,
            lastSequence: lastSequence,
            phoneOwnsActivity: presenter.isShowingPhoneRest,
            watchActivityShowing: watchRestRequested || presenter.isShowingWatchRest,
            now: now
        )
        if decision.recordSequence {
            lastLaunchId = snapshot.launchId
            lastSequence = snapshot.sequence
        }
        switch decision.action {
        case .show(let endDate, let label):
            watchRestRequested = true
            presenter.showWatchRest(
                endDate: endDate,
                exerciseLabel: label,
                workoutId: snapshot.workoutId ?? snapshot.sessionId
            )
            scheduleEnd(at: endDate)
        case .dismiss:
            watchRestRequested = false
            clearEnd()
            presenter.endWatchRest()
        case .ignore:
            break
        }
    }

    /// Closes the mirrored card once its interval is over. A phone that was suspended during the
    /// rest does this on its next wake, so a finished rest never stays on the Lock Screen.
    func dismissIfElapsed(now: Date = Date()) {
        let showing = watchRestRequested || presenter.isShowingWatchRest
        guard let scheduledEnd, scheduledEnd <= now, showing else { return }
        watchRestRequested = false
        clearEnd()
        presenter.endWatchRest()
    }

    private func scheduleEnd(at date: Date) {
        scheduledEnd = date
        endTask?.cancel()
        endTask = Task { [weak self] in
            let delay = max(0, date.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismissIfElapsed()
        }
    }

    private func clearEnd() {
        scheduledEnd = nil
        endTask?.cancel()
        endTask = nil
    }

    /// Forgets the delivery history, for example when the watch is unpaired or revoked.
    func reset() {
        lastLaunchId = nil
        lastSequence = 0
        watchRestRequested = false
        clearEnd()
    }
}
