import StrengthCore
import SwiftUI

/// Read-only plan for the active session. It never selects, clears or starts anything, so opening
/// it cannot bypass the exercise navigation lock or disturb an active set.
struct WatchPlanView: View {
    @ObservedObject var execution: WatchExecutionController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Plan").font(.headline)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityIdentifier("watch-plan-close")
                }

                WatchStaleWarning(isStale: execution.isStale)

                if execution.planRows.isEmpty {
                    Text("No exercises in this plan.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(execution.planRows) { row in
                        planRow(row)
                    }
                    Text("Read-only. Tap End exercise on the Set screen to change exercise.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if execution.planUpdated {
                    Text("Plan updated")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 2)
        }
        .accessibilityIdentifier("watch-plan")
    }

    private func planRow(_ row: WatchPlanRow) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon(row.status))
                .font(.caption2)
                .foregroundStyle(color(row.status))
            VStack(alignment: .leading, spacing: 1) {
                Text(exerciseName(row.exerciseId))
                    .font(.subheadline)
                Text("\\(row.completedSets) of \\(row.plannedSets) done")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(label(row.status))
                    .font(.caption2)
                    .foregroundStyle(color(row.status))
            }
        }
        .accessibilityIdentifier("watch-plan-row-\\(row.orderIndex)")
    }

    private func icon(_ status: WatchPlanRow.Status) -> String {
        switch status {
        case .completed: return "checkmark.circle.fill"
        case .current: return "arrow.right.circle.fill"
        case .upcoming: return "circle"
        }
    }

    private func color(_ status: WatchPlanRow.Status) -> Color {
        switch status {
        case .completed: return .green
        case .current: return .orange
        case .upcoming: return .gray
        }
    }

    private func label(_ status: WatchPlanRow.Status) -> String {
        switch status {
        case .completed: return "Completed"
        case .current: return "Current"
        case .upcoming: return "Upcoming"
        }
    }

    private func exerciseName(_ id: String) -> String {
        guard !id.isEmpty else { return "Exercise" }
        return id
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

/// Advisory, server-derived idle warning. It never changes or closes the workout.
struct WatchStaleWarning: View {
    let isStale: Bool

    var body: some View {
        if isStale {
            Text("No activity for 3h — the server may abandon this session.")
                .font(.caption2)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("watch-stale-warning")
        }
    }
}
