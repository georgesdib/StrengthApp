import StrengthCore
import SwiftUI

struct WatchExecutionView: View {
    @ObservedObject var execution: WatchExecutionController
    @State private var page = 0
    @State private var showingFinish = false

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
            default:
                TabView(selection: $page) {
                    WatchSetPage(execution: execution, showingFinish: $showingFinish)
                        .tag(0)
                    WatchSessionPage(execution: execution, showingFinish: $showingFinish)
                        .tag(1)
                }
                .tabViewStyle(.page)
            }
        }
        .sheet(isPresented: $showingFinish) {
            WatchFinishView(execution: execution)
        }
    }
}

// MARK: - Set page

struct WatchSetPage: View {
    @ObservedObject var execution: WatchExecutionController
    @Binding var showingFinish: Bool

    @State private var loadKg: Double = 0
    @State private var reps: Int = 5
    @State private var showingRIR = false
    @State private var logging = false
    @State private var preparedFor: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let item = execution.currentItem {
                    Text(exerciseName(item))
                        .font(.headline)
                    Text("Set \(setNumber(item)) of \(item.sets ?? 0)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(item.loadLabel) × \(item.repsLabel)")
                        .font(.title3)
                    Text(item.effortLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if execution.activeSet == nil {
                        Button("Start set") {
                            execution.beginSet(loadKg: loadKg, reps: reps)
                        }
                        .font(.footnote)
                    } else {
                        Text("Set in progress")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    loadRow
                    repsRow
                    Button {
                        showingRIR = true
                    } label: {
                        Text("Log set")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(logging || execution.isWorking)
                    .accessibilityIdentifier("watch-log-set")
                } else {
                    Text("No exercise to log. Refresh the plan on the iPhone.")
                        .font(.footnote)
                }

                if let rest = execution.rest, rest.isOpen {
                    WatchRestBar(execution: execution, rest: rest)
                }

                if execution.pendingCount > 0 || execution.isOffline {
                    Text(banner)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if let error = execution.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                if execution.exerciseItemIndex != nil {
                    Button("Done with exercise") { execution.doneWithExercise() }
                        .font(.footnote)
                }
                if execution.canUndo {
                    Button("Undo last set") { execution.undoLastSet() }
                        .font(.footnote)
                }
                Button("Finish") { showingFinish = true }
                    .font(.footnote)
            }
        }
        .onAppear { prepare() }
        .onChange(of: execution.currentItem?.exerciseId) { _, _ in prepare() }
        .onChange(of: execution.currentItem?.orderIndex) { _, _ in prepare() }
        .onChange(of: loadKg) { _, value in execution.draftChanged(loadKg: value, reps: reps) }
        .onChange(of: reps) { _, value in execution.draftChanged(loadKg: loadKg, reps: value) }
        .sheet(isPresented: $showingRIR) { rirPicker }
    }

    private var loadRow: some View {
        HStack {
            Text("\(formatted(loadKg)) kg").font(.body).monospacedDigit()
            Spacer()
            Button("−") { adjustLoad(-2.5) }
            Button("+") { adjustLoad(2.5) }
        }
        .focusable()
        .digitalCrownRotation(
            $loadKg,
            from: 0,
            through: 400,
            by: 2.5,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .accessibilityIdentifier("watch-load")
    }

    private var repsRow: some View {
        HStack {
            Text("\(reps) reps").font(.body).monospacedDigit()
            Spacer()
            Button("−") { reps = max(0, reps - 1) }
            Button("+") { reps += 1 }
        }
        .accessibilityIdentifier("watch-reps")
    }

    private var rirPicker: some View {
        ScrollView {
            VStack(spacing: 4) {
                Text("Reps in reserve").font(.headline)
                Text("How many reps were left?").font(.caption2).foregroundStyle(.secondary)
                ForEach(0...6, id: \.self) { value in
                    Button("\(value)") { log(rir: value) }
                }
                Button("Not recorded") { log(rir: nil) }
            }
        }
    }

    private var banner: String {
        if execution.isOffline {
            return "Offline · \(execution.pendingCount) pending"
        }
        return "\(execution.pendingCount) pending"
    }

    private func log(rir: Int?) {
        showingRIR = false
        logging = true
        Task {
            await execution.logSet(loadKg: loadKg, reps: reps, rir: rir)
            logging = false
            prepare()
        }
    }

    private func prepare() {
        guard let item = execution.currentItem else { return }
        let itemIndex = item.orderIndex ?? -1
        let key = "\(itemIndex)-\(item.exerciseId ?? "")"
        guard preparedFor != key else { return }
        preparedFor = key
        if let active = execution.activeSet, active.planItemIndex == itemIndex {
            // A terminated session restored its draft: keep the lifter's adjustments.
            loadKg = active.loadKg ?? item.loadKg ?? loadKg
            reps = active.reps ?? item.repsLow ?? item.repsHigh ?? reps
        } else {
            loadKg = item.loadKg ?? loadKg
            reps = item.repsLow ?? item.repsHigh ?? reps
        }
    }

    private func adjustLoad(_ delta: Double) {
        loadKg = max(0, loadKg + delta)
    }

    private func formatted(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%.1f", value)
    }

    private func exerciseName(_ item: PrescriptionItem) -> String {
        guard let id = item.exerciseId, !id.isEmpty else { return "Exercise" }
        return id
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private func setNumber(_ item: PrescriptionItem) -> Int {
        execution.completedSetCount(for: item) + 1
    }
}

// MARK: - Rest

struct WatchRestBar: View {
    @ObservedObject var execution: WatchExecutionController
    var rest: RestInterval

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 4) {
                if rest.isComplete(at: context.date) {
                    Text("Rest complete").font(.subheadline)
                } else {
                    let remaining = Int(rest.remaining(at: context.date).rounded(.up))
                    Text("Rest \(remaining / 60):\(String(format: "%02d", remaining % 60))")
                        .font(.subheadline)
                        .monospacedDigit()
                }
                HStack {
                    Button("+15s") { execution.extendRest(by: 15) }
                    Button("End rest") { execution.endRest() }
                }
                .font(.caption2)
            }
        }
    }
}

// MARK: - Session page

struct WatchSessionPage: View {
    @ObservedObject var execution: WatchExecutionController
    @Binding var showingFinish: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Elapsed \(elapsed(at: context.date))").font(.headline)
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
                if let error = execution.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                Button("Retry sync") {
                    Task { await execution.flushNow() }
                }
                .font(.footnote)
                Button("Finish") { showingFinish = true }
                    .font(.footnote)
            }
        }
    }

    private var plannedSets: Int {
        execution.workout?.plan?.items.reduce(0) { $0 + ($1.sets ?? 0) } ?? 0
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
    @State private var confirmingDiscard = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Workout complete").font(.headline)
                Text("\(execution.completedSetCount) sets")
                    .font(.caption)
                if execution.rest != nil {
                    Text("Rest state cleared").font(.caption2)
                }
                Button("Done") { execution.dismissSummary() }
                    .font(.footnote)
            }
        }
    }
}
