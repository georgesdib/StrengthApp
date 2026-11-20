import StrengthCore
import SwiftUI

/// The read-only exercise list: the watch selects an exercise but never edits the plan.
struct WatchExerciseListView: View {
    @ObservedObject var execution: WatchExecutionController
    @Binding var showingSession: Bool
    @Binding var showingPlan: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Exercises").font(.headline)
                    Spacer()
                    Button {
                        Task { await execution.reconcileNow() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("watch-refresh-plan")
                    Button {
                        showingPlan = true
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityIdentifier("watch-plan")
                    Button {
                        showingSession = true
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("watch-session")
                }

                if execution.planItems.isEmpty {
                    Text("No exercises in this plan.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(execution.planItems.enumerated()), id: \.element.id) { index, item in
                    let row = execution.executionRow(for: item)
                    Button {
                        execution.select(item)
                    } label: {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(exerciseName(item))
                                    .font(.subheadline)
                                if row?.kind == .substituted {
                                    Text("Changed on phone")
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                        .accessibilityIdentifier("watch-substituted-\(index)")
                                }
                                if let groups = row?.groups, !groups.isEmpty {
                                    // One row per planned group, in order, so the top set and
                                    // its back-off are both visible (DEC-RESOLVER-18).
                                    ForEach(Array(groups.enumerated()), id: \.offset) {
                                        groupIndex, group in
                                        Text(group.rowLabel)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .accessibilityIdentifier(
                                                "watch-group-\(index)-\(groupIndex)"
                                            )
                                    }
                                } else if let row, row.kind == .substituted {
                                    Text(row.repsLabel + " · " + row.loadLabel)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .accessibilityIdentifier("watch-substitute-target-\(index)")
                                }
                                Text("\(execution.completedSetCount(for: item)) of \(item.sets ?? 0)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if execution.completedSetCount(for: item) >= (item.sets ?? 0) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("watch-exercise-\(index)")
                }

                ForEach(execution.executionRows.filter { $0.kind == .added }) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(WatchExecutionController.displayName(forExercise: row.exerciseId))
                            .font(.subheadline)
                        Text("Extra work · " + row.repsLabel + " · " + row.loadLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("watch-addition-" + row.id)
                }

                WatchStaleWarning(isStale: execution.isStale)
                if execution.planUpdated {
                    Text("Plan updated")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
                if execution.pendingCount > 0 || execution.isOffline {
                    Text(banner)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if let liveness = execution.liveness.banner {
                    Text(liveness)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if let error = execution.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var banner: String {
        execution.isOffline
            ? "Offline · \(execution.pendingCount) pending"
            : "\(execution.pendingCount) pending"
    }

    private func exerciseName(_ item: PrescriptionItem) -> String {
        let id = execution.executionRow(for: item)?.exerciseId ?? item.exerciseId ?? ""
        return WatchExecutionController.displayName(forExercise: id)
    }
}
