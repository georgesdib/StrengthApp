import StrengthCore
import SwiftUI

/// The read-only exercise list: the watch selects an exercise but never edits the plan.
struct WatchExerciseListView: View {
    @ObservedObject var execution: WatchExecutionController
    @Binding var showingSession: Bool

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

                ForEach(execution.planItems) { item in
                    Button {
                        execution.select(item)
                    } label: {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(exerciseName(item))
                                    .font(.subheadline)
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
                }

                if execution.isStale {
                    Text("No activity for 3h — the server may abandon this session.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
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
        guard let id = item.exerciseId, !id.isEmpty else { return "Exercise" }
        return id
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
