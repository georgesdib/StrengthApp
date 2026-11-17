import ActivityKit
import StrengthCore
import SwiftUI
import WidgetKit

/// The rest countdown on the Lock Screen and in the Dynamic Island. The system renders the
/// remaining time from the activity's end date, so no app process is needed to keep it correct.
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

private struct RestLockScreenView: View {
    let context: ActivityViewContext<RestActivityAttributes>

    var body: some View {
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
