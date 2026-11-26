import ActivityKit
import Foundation
import StrengthCore
import UIKit
import os

/// Owns the single workout Live Activity.
///
/// The card is scoped to the training session rather than to one rest: while a rest is open it
/// renders the system countdown, and between rests it shows the session's active state. That scope
/// exists because ActivityKit only allows an activity to be *started* in the foreground; updating
/// an existing one is allowed from the background, which is how a rest reported by the Apple Watch
/// keeps the same card current after the first foreground start.
///
/// Exactly one activity exists at a time. The origin decides who may update or close the resting
/// state: a rest started on the phone wins over a mirrored watch rest, and the wrist owns its own
/// interval.
@MainActor
final class WorkoutLiveActivityController {
    static let shared = WorkoutLiveActivityController()

    private var stored: Activity<WorkoutActivityAttributes>?
    private var currentState: WorkoutActivityAttributes.ContentState?
    private var isStarting = false
    private let log = Logger(subsystem: "com.georgesdibpersonalteam.StrengthApp", category: "WorkoutActivity")

    /// The activity the system still lists. An activity ended outside this object — for example by
    /// the Live Activity's Skip button or by the person dismissing it — must not keep the next
    /// rest from showing.
    private var activity: Activity<WorkoutActivityAttributes>? {
        guard let stored else { return nil }
        guard Activity<WorkoutActivityAttributes>.activities.contains(where: { $0.id == stored.id })
        else { return nil }
        return stored
    }

    var hasActivity: Bool { activity != nil }
    var isShowingPhoneRest: Bool {
        activity != nil && currentState?.phase == .resting && currentState?.source == .phone
    }
    var isShowingWatchRest: Bool {
        activity != nil && currentState?.phase == .resting && currentState?.source == .watch
    }

    /// The workout the current card was last told about.
    var workoutId: String? {
        let value = currentState?.workoutId ?? ""
        return value.isEmpty ? nil : value
    }

    /// Re-reads the card the system holds, picking up a change an intent made in this process
    /// while the controller was suspended.
    func refreshFromActivity() {
        guard let current = activity else {
            currentState = nil
            return
        }
        currentState = current.content.state
    }

    /// Picks up a card this object did not create, which happens after a relaunch or when a
    /// notification tap started the activity in an earlier process. A rest that ended while the
    /// app was gone is moved to the active state instead of lingering as a countdown at zero.
    func adoptExisting() {
        guard stored == nil else { return }
        let activities = Activity<WorkoutActivityAttributes>.activities
        guard let first = activities.first else { return }
        stored = first
        currentState = first.content.state
        for extra in activities.dropFirst() {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
        if let state = currentState, state.phase == .resting,
           let end = state.endDate, end <= Date() {
            setActive(source: state.source, workoutId: state.workoutId)
        }
    }

    // MARK: - Resting

    /// Starts or refreshes a rest. Returns false when the card does not exist and the process is
    /// not in the foreground: the caller then falls back to a notification the person can tap.
    @discardableResult
    func startRest(
        source: WorkoutActivityAttributes.Source,
        endDate: Date,
        exerciseLabel: String,
        workoutId: String
    ) -> Bool {
        show(
            WorkoutActivityAttributes.ContentState(
                phase: .resting,
                source: source,
                workoutId: workoutId,
                endDate: endDate,
                exerciseLabel: exerciseLabel
            )
        )
    }

    /// Starts the card in its active state, or refreshes an existing one. Used when a workout is
    /// started in the foreground or when the app opens during a watch session; a background call
    /// without an existing card is a no-op so no notification is lost.
    @discardableResult
    func startActive(source: WorkoutActivityAttributes.Source, workoutId: String) -> Bool {
        guard !workoutId.isEmpty else { return false }
        return show(
            WorkoutActivityAttributes.ContentState(
                phase: .active,
                source: source,
                workoutId: workoutId
            )
        )
    }

    private func show(_ state: WorkoutActivityAttributes.ContentState) -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log.error("Live Activities are disabled for Strength")
            return false
        }
        if stored == nil { adoptExisting() }
        if let current = activity {
            // A card now exists, so any watch rest prompt it supersedes is stale.
            WatchRestNotifier.shared.cancel()
            currentState = state
            let content = content(for: state)
            Task { await current.update(content) }
            return true
        }
        // Starting is foreground-only; a background start is refused by ActivityKit and must be
        // replaced by the notification fallback instead of failing silently.
        guard UIApplication.shared.applicationState == .active else { return false }
        WatchRestNotifier.shared.cancel()
        guard !isStarting else { return true }
        isStarting = true
        currentState = state
        let content = content(for: state)
        Task { [weak self] in
            await Self.closeAll()
            do {
                let requested = try Activity.request(
                    attributes: WorkoutActivityAttributes(),
                    content: content
                )
                guard let self else {
                    await requested.end(nil, dismissalPolicy: .immediate)
                    return
                }
                self.stored = requested
                self.currentState = state
                self.isStarting = false
            } catch {
                self?.stored = nil
                self?.currentState = nil
                self?.isStarting = false
                self?.log.error("Could not start the workout Live Activity: \(error.localizedDescription, privacy: .public)")
            }
        }
        return true
    }

    // MARK: - Active

    /// Moves the card between rests (or from a phone-owned rest after Skip). Never starts a card:
    /// a background wake may only update one that already exists.
    func setActive(source: WorkoutActivityAttributes.Source, workoutId: String? = nil) {
        if stored == nil { adoptExisting() }
        guard let current = activity else { return }
        let state = WorkoutActivityAttributes.ContentState(
            phase: .active,
            source: source,
            workoutId: workoutId ?? currentState?.workoutId ?? ""
        )
        currentState = state
        let content = content(for: state)
        Task { await current.update(content) }
    }

    // MARK: - Ending

    /// Ends the card when the workout it represents is over. A workout id mismatch leaves the
    /// card alone so a late finish from the previous session cannot close the next one.
    func endWorkout(_ workoutId: String) {
        if stored == nil { adoptExisting() }
        guard let current = activity else {
            stored = nil
            currentState = nil
            return
        }
        let showing = currentState?.workoutId ?? ""
        guard workoutId.isEmpty || showing.isEmpty || showing == workoutId else { return }
        stored = nil
        currentState = nil
        Task { await current.end(nil, dismissalPolicy: .immediate) }
    }

    func endAll() {
        stored = nil
        currentState = nil
        Task { await Self.closeAll() }
    }

    // MARK: - Shared

    private func content(
        for state: WorkoutActivityAttributes.ContentState
    ) -> ActivityContent<WorkoutActivityAttributes.ContentState> {
        let staleDate: Date
        switch state.phase {
        case .resting:
            staleDate = (state.endDate ?? Date()).addingTimeInterval(600)
        case .active:
            staleDate = Date().addingTimeInterval(8 * 60 * 60)
        }
        return ActivityContent(state: state, staleDate: staleDate)
    }

    private static func closeAll() async {
        for activity in Activity<WorkoutActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    static func label(forExerciseId exerciseId: String?) -> String {
        guard let exerciseId, !exerciseId.isEmpty else { return "Rest" }
        return exerciseId
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
