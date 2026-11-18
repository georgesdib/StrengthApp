import ActivityKit
import AppIntents
import StrengthCore
import SwiftUI
import WidgetKit

/// The rest countdown on the Lock Screen and in the Dynamic Island. The system renders the
/// remaining time from the activity's end date, so no app process is needed to keep it correct.
/// The two buttons run `LiveActivityIntent`s in the app's process: the interval is extended or
/// closed at the tap, without opening the app or unlocking the phone.
struct RestLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RestActivityAttributes.self) { context in
            RestLockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.65))
                .activitySystemActionForegroundColor(.orange)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.exerciseLabel, systemImage: "timer")
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RestCountdown(endDate: context.state.endDate)
                        .font(.title3.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RestControls()
                }
            } compactLeading: {
                Image(systemName: "timer")
            } compactTrailing: {
                RestCountdown(endDate: context.state.endDate)
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "timer")
            }
            .keylineTint(.orange)
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

private struct RestLockScreenView: View {
    let context: ActivityViewContext<RestActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rest")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(context.state.exerciseLabel)
                        .font(.headline)
                }
                Spacer()
                RestCountdown(endDate: context.state.endDate)
                    .font(.title2.monospacedDigit())
            }
            RestControls()
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
