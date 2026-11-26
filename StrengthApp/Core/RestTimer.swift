import Combine
import Foundation
import SwiftUI
import StrengthCore

struct RestTimerResult: Equatable {
    let startedAt: Date
    let endedAt: Date
    let prescribedSeconds: Int
    let actualSeconds: Int
    let addedSeconds: Int
    let outcome: String
    let planItemIndex: Int?
    let exerciseId: String?
    let reason: String?

    init(
        startedAt: Date,
        endedAt: Date,
        prescribedSeconds: Int,
        actualSeconds: Int,
        addedSeconds: Int,
        outcome: String,
        planItemIndex: Int? = nil,
        exerciseId: String? = nil,
        reason: String? = nil
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.prescribedSeconds = prescribedSeconds
        self.actualSeconds = actualSeconds
        self.addedSeconds = addedSeconds
        self.outcome = outcome
        self.planItemIndex = planItemIndex
        self.exerciseId = exerciseId
        self.reason = reason
    }
}

/// One rest interval for the whole app. The timer is owned by AppModel so it survives navigation
/// to Today and can be shown from the tab shell; it never depends on a workout screen being alive.
@MainActor
final class RestTimerModel: ObservableObject {
    @Published private(set) var endDate: Date?
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var isComplete = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var prescribedSeconds: Int?
    @Published private(set) var addedSeconds = 0
    @Published private(set) var planItemIndex: Int?
    @Published private(set) var exerciseId: String?

    /// Called exactly once when an interval ends, whichever path ended it. AppModel records the
    /// execution event from here so completion does not depend on the visible screen.
    var onFinish: ((RestTimerResult) -> Void)?
    var onExtend: ((Int) -> Void)?

    private var ticker: Task<Void, Never>?
    private var workoutId: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isRunning: Bool { endDate != nil && !isComplete }

    func start(
        seconds: Int,
        planItemIndex: Int? = nil,
        exerciseId: String? = nil,
        startedAt anchor: Date? = nil,
        workoutId: String? = nil
    ) {
        guard seconds > 0 else { return }
        ticker?.cancel()
        // The rest is anchored where the set ended (the first edit of the log sheet), not at
        // save time, so the entry itself is rest.
        let now = anchor ?? Date()
        startedAt = now
        prescribedSeconds = seconds
        addedSeconds = 0
        let end = now.addingTimeInterval(TimeInterval(seconds))
        endDate = end
        remainingSeconds = max(0, Int(end.timeIntervalSinceNow.rounded(.up)))
        isComplete = remainingSeconds == 0
        self.planItemIndex = planItemIndex
        self.exerciseId = exerciseId
        self.workoutId = workoutId
        persist()
        RestNotificationManager.shared.scheduleRestEnd(after: remainingSeconds)
        WorkoutLiveActivityController.shared.startRest(
            source: .phone,
            endDate: end,
            exerciseLabel: WorkoutLiveActivityController.label(forExerciseId: exerciseId),
            workoutId: workoutId ?? ""
        )
        startTicker()
    }

    /// Restores the interval after a relaunch. A live interval resumes counting; one that ended
    /// while the app was gone is returned so the caller can record it at its real end time.
    func restore(workoutId: String?, now: Date = Date()) -> RestTimerResult? {
        guard let state = RestActivityStore.load(from: defaults) else { return nil }
        guard let workoutId, state.workoutId == workoutId else {
            RestActivityStore.clear(from: defaults)
            return nil
        }
        let end = state.startedAt.addingTimeInterval(
            TimeInterval(state.prescribedSeconds + state.addedSeconds)
        )
        guard end > now else {
            RestActivityStore.clear(from: defaults)
            return RestTimerResult(
                startedAt: state.startedAt,
                endedAt: end,
                prescribedSeconds: state.prescribedSeconds,
                actualSeconds: max(0, state.prescribedSeconds + state.addedSeconds),
                addedSeconds: state.addedSeconds,
                outcome: "completed",
                planItemIndex: state.planItemIndex,
                exerciseId: state.exerciseId
            )
        }
        startedAt = state.startedAt
        prescribedSeconds = state.prescribedSeconds
        addedSeconds = state.addedSeconds
        planItemIndex = state.planItemIndex
        exerciseId = state.exerciseId
        self.workoutId = state.workoutId
        endDate = end
        isComplete = false
        remainingSeconds = max(0, Int(end.timeIntervalSince(now).rounded(.up)))
        RestNotificationManager.shared.scheduleRestEnd(after: remainingSeconds)
        WorkoutLiveActivityController.shared.startRest(
            source: .phone,
            endDate: end,
            exerciseLabel: WorkoutLiveActivityController.label(forExerciseId: exerciseId),
            workoutId: workoutId ?? ""
        )
        startTicker()
        return nil
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    private func persist() {
        guard let startedAt, let prescribedSeconds else { return }
        RestActivityStore.save(
            RestActivityState(
                workoutId: workoutId,
                startedAt: startedAt,
                prescribedSeconds: prescribedSeconds,
                addedSeconds: addedSeconds,
                planItemIndex: planItemIndex,
                exerciseId: exerciseId
            ),
            to: defaults
        )
    }

    func extend(by seconds: Int) {
        guard let endDate, seconds > 0 else { return }
        self.endDate = endDate.addingTimeInterval(TimeInterval(seconds))
        remainingSeconds = max(0, remainingSeconds + seconds)
        addedSeconds += seconds
        isComplete = false
        persist()
        RestNotificationManager.shared.scheduleRestEnd(after: remainingSeconds)
        WorkoutLiveActivityController.shared.startRest(
            source: .phone,
            endDate: self.endDate!,
            exerciseLabel: WorkoutLiveActivityController.label(forExerciseId: exerciseId),
            workoutId: workoutId ?? ""
        )
        onExtend?(seconds)
    }

    /// Ends the current rest and returns the observed interval. nil means no rest was running.
    /// `endedAt` defaults to now; the ticker passes the scheduled end so a rest that elapsed while
    /// the app was suspended is recorded with the duration it actually took.
    func finish(
        outcome: String = "completed",
        reason: String? = nil,
        endedAt: Date = Date()
    ) -> RestTimerResult? {
        guard let startedAt, let prescribedSeconds else { return nil }
        let result = RestTimerResult(
            startedAt: startedAt,
            endedAt: endedAt,
            prescribedSeconds: prescribedSeconds,
            actualSeconds: max(0, Int(endedAt.timeIntervalSince(startedAt))),
            addedSeconds: addedSeconds,
            outcome: outcome,
            planItemIndex: planItemIndex,
            exerciseId: exerciseId,
            reason: reason
        )
        dismiss()
        onFinish?(result)
        return result
    }

    func dismiss() {
        RestNotificationManager.shared.cancel()
        // The card is workout-scoped: the rest is over, but the session is not. The workout's
        // finish/abandon path ends the activity itself.
        WorkoutLiveActivityController.shared.setActive(source: .phone)
        RestActivityStore.clear(from: defaults)
        clearPublishedState()
    }

    private func clearPublishedState() {
        ticker?.cancel()
        ticker = nil
        endDate = nil
        remainingSeconds = 0
        isComplete = false
        startedAt = nil
        prescribedSeconds = nil
        addedSeconds = 0
        planItemIndex = nil
        exerciseId = nil
    }

    /// Applies a change the Live Activity made while the app was elsewhere, and consumes a rest
    /// it ended. Returns the interval to record when the rest was skipped there, so the caller
    /// records it exactly once; nil means nothing was recorded.
    func reconcileExternalChanges(workoutId: String? = nil, now: Date = Date()) -> RestTimerResult? {
        if let completion = RestActivityStore.takeCompletion(from: defaults) {
            RestNotificationManager.shared.cancel()
            clearPublishedState()
            // A rest from a workout that is no longer active has nothing to attribute it to.
            guard let workoutId, completion.workoutId == workoutId else { return nil }
            return RestTimerResult(
                startedAt: completion.startedAt,
                endedAt: completion.endedAt,
                prescribedSeconds: completion.prescribedSeconds,
                actualSeconds: max(0, Int(completion.endedAt.timeIntervalSince(completion.startedAt))),
                addedSeconds: completion.addedSeconds,
                outcome: completion.outcome,
                planItemIndex: completion.planItemIndex,
                exerciseId: completion.exerciseId
            )
        }
        guard let state = RestActivityStore.load(from: defaults) else { return nil }
        if !state.isComplete(at: now) {
            apply(state, now: now)
        }
        return nil
    }

    /// Makes the persisted interval the live one, so an extension made from the Lock Screen shows
    /// up in the tab bar without a relaunch.
    private func apply(_ state: RestActivityState, now: Date) {
        startedAt = state.startedAt
        prescribedSeconds = state.prescribedSeconds
        addedSeconds = state.addedSeconds
        planItemIndex = state.planItemIndex
        exerciseId = state.exerciseId
        workoutId = state.workoutId
        endDate = state.endsAt
        isComplete = false
        remainingSeconds = max(0, Int(state.endsAt.timeIntervalSince(now).rounded(.up)))
        RestNotificationManager.shared.scheduleRestEnd(after: remainingSeconds)
        startTicker()
    }

    private func tick() {
        refresh()
    }

    /// Recomputes the countdown at `now` and finishes centrally when it has elapsed. Exposed for
    /// deterministic tests; the ticker calls it once per second.
    func refresh(now: Date = Date()) {
        guard let endDate else { return }
        let remaining = Int(endDate.timeIntervalSince(now).rounded(.up))
        if remaining <= 0 {
            // The Lock Screen can extend the rest while the ticker is between ticks; trust the
            // persisted interval over the in-memory end date.
            if let state = RestActivityStore.load(from: defaults), !state.isComplete(at: now) {
                apply(state, now: now)
                return
            }
            remainingSeconds = 0
            isComplete = true
            ticker?.cancel()
            ticker = nil
            RestNotificationManager.shared.completeInApp()
            // Finish centrally so a rest that ends on Today is recorded and dismissed too.
            _ = finish(outcome: "completed", endedAt: endDate)
        } else {
            remainingSeconds = remaining
        }
    }
}

struct RestTimerBar: View {
    @ObservedObject var timer: RestTimerModel

    var body: some View {
        if timer.endDate != nil {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 12) {
                    Image(systemName: timer.isComplete ? "checkmark.circle.fill" : "timer")
                        .foregroundStyle(timer.isComplete ? .green : .orange)
                    Text(timer.isComplete ? "Rest complete" : "Rest \(Self.format(timer.remainingSeconds))")
                        .font(.headline)
                    Spacer()
                    if !timer.isComplete {
                        Button("+15s") {
                            timer.extend(by: 15)
                        }
                        .font(.footnote)
                    }
                    Button(timer.isComplete ? "Done" : "Skip") {
                        _ = timer.finish(outcome: timer.isComplete ? "completed" : "skipped")
                    }
                    .font(.footnote)
                }
                if let prescribed = timer.prescribedSeconds {
                    Text(timer.addedSeconds > 0
                         ? "Prescribed \(prescribed)s · extended \(timer.addedSeconds)s"
                         : "Prescribed \(prescribed)s")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("rest-timer")
        }
    }

    private static func format(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
