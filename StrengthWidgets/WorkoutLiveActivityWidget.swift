import ActivityKit
import AppIntents
import StrengthCore
import SwiftUI
import WidgetKit

/// The workout card on the Lock Screen and in the Dynamic Island. During a rest the system renders
/// the remaining time from the activity's end date, so no app process is needed to keep it
/// correct. Between rests the same card shows the session's active state, which is why one card
/// covers the whole workout. The two rest buttons run `LiveActivityIntent`s in the app's process:
/// the interval is extended or closed at the tap, without opening the app or unlocking the phone.
struct WorkoutLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            WorkoutLockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.65))
                .activitySystemActionForegroundColor(.orange)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(WorkoutCard.title(for: context.state), systemImage: WorkoutCard.icon(for: context.state))
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    WorkoutCard.trailing(for: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    WorkoutFooterView(state: context.state)
                }
            } compactLeading: {
                Image(systemName: WorkoutCard.icon(for: context.state))
            } compactTrailing: {
                WorkoutCard.trailing(for: context.state)
            } minimal: {
                Image(systemName: WorkoutCard.icon(for: context.state))
            }
            .keylineTint(.orange)
        }
    }
}

/// Shared copy and icons for both presentations.
private enum WorkoutCard {
    static func isResting(_ state: WorkoutActivityAttributes.ContentState) -> Bool {
        state.phase == .resting
    }

    static func title(for state: WorkoutActivityAttributes.ContentState) -> String {
        guard isResting(state) else { return "Workout" }
        let label = state.exerciseLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? "Rest" : label
    }

    static func icon(for state: WorkoutActivityAttributes.ContentState) -> String {
        isResting(state) ? "timer" : "figure.strengthtraining.traditional"
    }

    static func activeSubtitle(for state: WorkoutActivityAttributes.ContentState) -> String {
        state.source == .watch ? "On Apple Watch" : "On iPhone"
    }

    @ViewBuilder
    static func trailing(for state: WorkoutActivityAttributes.ContentState) -> some View {
        if isResting(state), let endDate = state.endDate {
            RestCountdown(endDate: endDate)
                .font(.title3.monospacedDigit())
        } else {
            Image(systemName: "figure.strengthtraining.traditional")
                .foregroundStyle(.orange)
        }
    }
}

/// A rest that belongs to a workout running on the Apple Watch is rendered, not controlled: the
/// wrist owns the interval, so the phone shows where it comes from instead of offering buttons
/// it cannot honour. The active state has nothing to control either.
private struct WorkoutFooterView: View {
    let state: WorkoutActivityAttributes.ContentState

    var body: some View {
        if WorkoutCard.isResting(state) {
            if state.source == .watch {
                Label("Rest on Apple Watch", systemImage: "applewatch")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                RestControls()
            }
        } else {
            Label(
                state.source == .watch ? "Next set on Apple Watch" : "Next set on iPhone",
                systemImage: state.source == .watch ? "applewatch" : "iphone"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

/// The compact Island and the minimal pill are too small for controls; these live on the Lock
/// Screen and in the expanded Island.
private struct RestControls: View {
    var body: some View {
        HStack(spacing: 16) {
            Button(intent: ExtendRestIntent()) {
                Label("+15 s", systemImage: "plus.circle")
            }
            Button(intent: SkipRestIntent()) {
                Label("Skip", systemImage: "forward.end.circle")
            }
        }
        .font(.footnote.bold())
        .buttonStyle(.plain)
    }
}

private struct WorkoutLockScreenView: View {
    let state: WorkoutActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(WorkoutCard.isResting(state) ? "Rest" : "Workout")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(
                        WorkoutCard.isResting(state)
                            ? WorkoutCard.title(for: state)
                            : WorkoutCard.activeSubtitle(for: state)
                    )
                    .font(.headline)
                }
                Spacer()
                if WorkoutCard.isResting(state), let endDate = state.endDate {
                    RestCountdown(endDate: endDate)
                        .font(.title2.monospacedDigit())
                } else {
                    Image(systemName: "figure.strengthtraining.traditional")
                        .font(.title2)
                        .foregroundStyle(.orange)
                }
            }
            WorkoutFooterView(state: state)
        }
        .padding()
    }
}

/// A self-updating timer text. The range must be valid, so a finished rest falls back to a label.
private struct RestCountdown: View {
    let endDate: Date

    var body: some View {
        if endDate > Date() {
            Text(timerInterval: Date()...endDate, countsDown: true)
                .multilineTextAlignment(.trailing)
        } else {
            Text("Ready")
        }
    }
}
