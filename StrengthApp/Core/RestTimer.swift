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

    var isRunning: Bool { endDate != nil && !isComplete }

    func start(
        seconds: Int,
        planItemIndex: Int? = nil,
        exerciseId: String? = nil,
        startedAt anchor: Date? = nil
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
        RestNotificationManager.shared.scheduleRestEnd(after: remainingSeconds)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    func extend(by seconds: Int) {
        guard let endDate, seconds > 0 else { return }
        self.endDate = endDate.addingTimeInterval(TimeInterval(seconds))
        remainingSeconds = max(0, remainingSeconds + seconds)
        addedSeconds += seconds
        isComplete = false
        RestNotificationManager.shared.scheduleRestEnd(after: remainingSeconds)
        onExtend?(seconds)
    }

    /// Ends the current rest and returns the observed interval. nil means no rest was running.
    func finish(outcome: String = "completed", reason: String? = nil) -> RestTimerResult? {
        guard let startedAt, let prescribedSeconds else { return nil }
        let result = RestTimerResult(
            startedAt: startedAt,
            endedAt: Date(),
            prescribedSeconds: prescribedSeconds,
            actualSeconds: max(0, Int(Date().timeIntervalSince(startedAt))),
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

    private func tick() {
        refresh()
    }

    /// Recomputes the countdown at `now` and finishes centrally when it has elapsed. Exposed for
    /// deterministic tests; the ticker calls it once per second.
    func refresh(now: Date = Date()) {
        guard let endDate else { return }
        let remaining = Int(endDate.timeIntervalSince(now).rounded(.up))
        if remaining <= 0 {
            remainingSeconds = 0
            isComplete = true
            ticker?.cancel()
            ticker = nil
            RestNotificationManager.shared.completeInApp()
            // Finish centrally so a rest that ends on Today is recorded and dismissed too.
            _ = finish(outcome: "completed")
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
