import StrengthCore
import SwiftUI

struct WatchExecutionView: View {
    @ObservedObject var execution: WatchExecutionController
    @State private var showingSession = false
    @State private var showingPlan = false

    var body: some View {
        Group {
            switch execution.phase {
            case .starting:
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Starting…").font(.footnote)
                }
            case .finishing:
                WatchFinishProgressView(execution: execution)
            case .finished:
                WatchFinishedView(execution: execution)
            case .abandoned:
                VStack(spacing: 8) {
                    Text("Session discarded").font(.headline)
                    Text("Nothing was saved for this session.").font(.caption2)
                    Button("Done") { execution.clearLocal() }
                        .font(.footnote)
                        .accessibilityIdentifier("watch-discarded-done")
                }
            case .readOnly:
                WatchReadOnlyView(execution: execution)
            case .ended(let reason):
                WatchEndedView(execution: execution, reason: reason)
            default:
                if execution.selectedItem == nil {
                    WatchExerciseListView(
                        execution: execution,
                        showingSession: $showingSession,
                        showingPlan: $showingPlan
                    )
                } else {
                    WatchExerciseView(
                        execution: execution,
                        showingSession: $showingSession,
                        showingPlan: $showingPlan
                    )
                }
            }
        }
        .sheet(isPresented: $showingSession) {
            WatchSessionSheet(execution: execution)
        }
        .sheet(isPresented: $showingPlan) {
            WatchPlanView(execution: execution)
        }
        // Finishing or discarding from a sheet leaves it presented over a screen that no longer
        // belongs to that sheet; close the stack when the phase leaves the active session.
        .onChange(of: execution.phase) { _, phase in
            if phase != .active {
                showingSession = false
                showingPlan = false
            }
        }
    }
}

// MARK: - Session sheet

struct WatchSessionSheet: View {
    @ObservedObject var execution: WatchExecutionController
    @Environment(\.dismiss) private var dismiss
    @State private var showingFinish = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Session").font(.headline)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityIdentifier("watch-session-close")
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Elapsed \(elapsed(at: context.date))")
                        .font(.title3)
                        .monospacedDigit()
                }
                Text("Sets \(execution.completedSetCount) done · \(max(0, plannedSets - execution.completedSetCount)) remaining")
                    .font(.caption)
                if execution.pendingSetCount > 0 {
                    Text("\(execution.pendingSetCount) sets pending")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text("Volume \(Int(execution.tonnageKg)) kg\(execution.pendingCount > 0 ? " (provisional)" : "")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let next = execution.nextExerciseName {
                    Text("Next: \(next)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                WatchStaleWarning(isStale: execution.isStale)
                Text(execution.isOffline ? "Offline — changes stay on the watch" : "Connected to home server")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if execution.isWorking {
                    ProgressView()
                        .controlSize(.mini)
                }
                if let banner = execution.liveness.banner {
                    Text(banner)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if let error = execution.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                Button("Refresh") {
                    Task { await execution.reconcileNow() }
                }
                .font(.footnote)
                .accessibilityIdentifier("watch-session-refresh")
                Button("Retry sync") {
                    Task { await execution.flushNow() }
                }
                .font(.footnote)
                if execution.canUndo {
                    Button("Undo last set") { execution.undoLastSet() }
                        .font(.footnote)
                }
                Button("Finish") { showingFinish = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("watch-open-finish")
            }
        }
        .sheet(isPresented: $showingFinish) {
            WatchFinishView(execution: execution)
        }
    }

    private var plannedSets: Int {
        execution.planItems.reduce(0) { $0 + ($1.sets ?? 0) }
    }

    private func elapsed(at date: Date) -> String {
        let seconds = Int(execution.elapsed(at: date))
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

// MARK: - Finish states

struct WatchFinishProgressView: View {
    @ObservedObject var execution: WatchExecutionController
    @State private var confirmingDiscard = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Finish saved on watch").font(.headline)
                Text(execution.finishAcknowledged
                     ? "Saved to the home server"
                     : execution.pendingCount > 0
                        ? "Syncing to the home server…"
                        : "The server has not confirmed this finish")
                    .font(.caption2)
                    .foregroundStyle(execution.finishAcknowledged ? Color.secondary : Color.orange)
                if execution.pendingCount > 0 {
                    Text("\(execution.pendingCount) pending")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if let error = execution.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                WatchHealthKitStatus(execution: execution)
                Button("Retry sync") {
                    Task { await execution.flushNow() }
                }
                .font(.footnote)
                Button("Discard session") { confirmingDiscard = true }
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .confirmationDialog(
            "Discard this session?",
            isPresented: $confirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard session", role: .destructive) {
                Task { await execution.discard() }
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The workout is abandoned and the local record is cleared.")
        }
    }
}

struct WatchFinishedView: View {
    @ObservedObject var execution: WatchExecutionController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Workout complete").font(.headline)
                Text("\(execution.completedSetCount) sets")
                    .font(.caption)
                if execution.offPlanNoted {
                    Text("Plan changed while offline — some sets were kept off-plan.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                WatchHealthKitStatus(execution: execution)
                Button("Done") { execution.dismissSummary() }
                    .font(.footnote)
                    .accessibilityIdentifier("watch-done")
            }
        }
    }
}

// MARK: - Ownership and ended states

struct WatchReadOnlyView: View {
    @ObservedObject var execution: WatchExecutionController
    @State private var confirmingClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Logging moved to the phone")
                    .font(.headline)
                Text("This watch can still show the session but cannot add sets.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(execution.completedSetCount) sets recorded")
                    .font(.caption)
                if execution.pendingCount > 0 {
                    Text("\(execution.pendingCount) waiting on the phone's session")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Button("Clear record") { confirmingClear = true }
                    .font(.footnote)
            }
        }
        .confirmationDialog(
            "Clear the local record?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear record", role: .destructive) { execution.clearLocal() }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The workout stays on the phone; nothing is abandoned.")
        }
    }
}

struct WatchEndedView: View {
    @ObservedObject var execution: WatchExecutionController
    var reason: WatchEndedReason
    @State private var confirmingClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(reason.title)
                    .font(.headline)
                    .accessibilityIdentifier("watch-ended-title")
                Text(reason.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(execution.completedSetCount) sets were recorded on this watch.")
                    .font(.caption)
                Button("Clear record") { confirmingClear = true }
                    .font(.footnote)
            }
        }
        .confirmationDialog(
            "Clear the local record?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear record", role: .destructive) { execution.clearLocal() }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The local snapshot is removed. The server's record is unchanged.")
        }
    }
}

// MARK: - HealthKit save status

struct WatchHealthKitStatus: View {
    @ObservedObject var execution: WatchExecutionController

    var body: some View {
        if let state = execution.healthKitState {
            switch state {
            case .pending:
                Text("Saving workout to Health…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .saved:
                Text("Saved to Health")
                    .font(.caption2)
                    .foregroundStyle(.green)
                if execution.effortState == .unavailable {
                    Text("Effort was not saved.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            case .unsaved:
                if !execution.healthKitNoticeDismissed {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The HealthKit workout was not saved.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        if let failure = execution.healthKitFailure {
                            Text(failure)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Try again") {
                                Task { await execution.retryHealthKit() }
                            }
                            Button("Dismiss") { execution.dismissHealthKitNotice() }
                        }
                        .font(.caption2)
                    }
                }
            }
        }
    }
}
