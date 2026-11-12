import StrengthCore
import SwiftUI

struct WatchExecutionView: View {
    @ObservedObject var execution: WatchExecutionController
    @State private var showingSession = false

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
                }
            case .readOnly:
                WatchReadOnlyView(execution: execution)
            case .ended(let reason):
                WatchEndedView(execution: execution, reason: reason)
            default:
                if execution.selectedItem == nil {
                    WatchExerciseListView(execution: execution, showingSession: $showingSession)
                } else {
                    WatchExerciseView(execution: execution, showingSession: $showingSession)
                }
            }
        }
        .sheet(isPresented: $showingSession) {
            WatchSessionSheet(execution: execution)
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
                Text("Sets \(execution.completedSetCount) of \(plannedSets)")
                    .font(.caption)
                if execution.pendingCount > 0 {
                    Text("\(execution.pendingCount) pending")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text(execution.isOffline ? "Offline" : "Home server")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                Text("Syncing to the home server…").font(.caption2)
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
                Button("Done") { execution.dismissSummary() }
                    .font(.footnote)
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
    var reason: String
    @State private var confirmingClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Session ended elsewhere")
                    .font(.headline)
                Text(reason)
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
