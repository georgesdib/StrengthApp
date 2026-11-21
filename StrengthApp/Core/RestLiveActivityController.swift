import ActivityKit
import Foundation
import StrengthCore

/// Owns the single rest Live Activity. The system renders the countdown from `endDate`, so the
/// app does not need to tick while the phone is locked or suspended.
///
/// Exactly one activity exists at a time, and its origin decides who may update or close it: a
/// rest started on the phone is never overwritten by a rest mirrored from the Apple Watch, and a
/// mirrored rest is never closed by the phone's own timer.
@MainActor
final class RestLiveActivityController: RestActivityPresenting {
    static let shared = RestLiveActivityController()

    enum Origin {
        case phone
        case watch
    }

    private var stored: Activity<RestActivityAttributes>?
    private(set) var origin: Origin?

    /// The activity the system still lists. An activity ended outside this object — for example by
    /// the Live Activity's Skip button — must not keep the mirror from showing the next rest.
    private var activity: Activity<RestActivityAttributes>? {
        guard let stored else { return nil }
        guard Activity<RestActivityAttributes>.activities.contains(where: { $0.id == stored.id })
        else { return nil }
        return stored
    }

    var isShowingPhoneRest: Bool { origin == .phone && activity != nil }
    var isShowingWatchRest: Bool { origin == .watch && activity != nil }

    // MARK: - Phone-owned rest

    func start(endDate: Date, exerciseId: String?, workoutId: String?) {
        show(
            attributes: RestActivityAttributes(workoutId: workoutId ?? ""),
            endDate: endDate,
            label: Self.label(exerciseId),
            origin: .phone
        )
    }

    func update(endDate: Date, exerciseId: String?) {
        guard origin == .phone, let current = activity else { return }
        let content = ActivityContent(
            state: RestActivityAttributes.ContentState(
                endDate: endDate,
                exerciseLabel: Self.label(exerciseId)
            ),
            staleDate: endDate.addingTimeInterval(600)
        )
        Task { await current.update(content) }
    }

    /// Closes a rest this phone started. A rest mirrored from the watch is left alone: the wrist
    /// owns it and says when it ends.
    func end() {
        guard origin != .watch else { return }
        origin = nil
        guard let current = activity else {
            stored = nil
            return
        }
        stored = nil
        Task { await current.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: - Rest mirrored from the watch

    func showWatchRest(endDate: Date, exerciseLabel: String, workoutId: String) {
        show(
            attributes: RestActivityAttributes(workoutId: workoutId, watchMirrored: true),
            endDate: endDate,
            label: exerciseLabel,
            origin: .watch
        )
    }

    func endWatchRest() {
        guard origin == .watch else { return }
        origin = nil
        guard let current = activity else {
            stored = nil
            return
        }
        stored = nil
        Task { await current.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: - Shared

    private func show(
        attributes: RestActivityAttributes,
        endDate: Date,
        label: String,
        origin: Origin
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = ActivityContent(
            state: RestActivityAttributes.ContentState(endDate: endDate, exerciseLabel: label),
            staleDate: endDate.addingTimeInterval(600)
        )
        // The widget renders controls from the attributes, so a change of origin needs a new
        // activity rather than an update of the existing one.
        if let current = activity, current.attributes.watchMirrored == attributes.watchMirrored {
            self.origin = origin
            Task { await current.update(content) }
            return
        }
        self.origin = origin
        Task {
            await Self.closeAll()
            do {
                stored = try Activity.request(attributes: attributes, content: content)
            } catch {
                stored = nil
                self.origin = nil
            }
        }
    }

    private static func closeAll() async {
        for activity in Activity<RestActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private static func label(_ exerciseId: String?) -> String {
        guard let exerciseId, !exerciseId.isEmpty else { return "Rest" }
        return exerciseId
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
