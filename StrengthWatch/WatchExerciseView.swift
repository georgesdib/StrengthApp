import StrengthCore
import SwiftUI

/// One exercise at a time: Start set → perform → End set (RIR) → rest → next set.
struct WatchExerciseView: View {
    @ObservedObject var execution: WatchExecutionController
    @Binding var showingSession: Bool
    @Binding var showingPlan: Bool

    @State private var loadKg = 0.0
    @State private var reps = 5
    @State private var showingRIR = false
    @State private var preparedFor: String?
    @State private var logging = false
    @State private var showingForm = false
    @State private var velocityText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let item = execution.selectedItem {
                    header(item)
                    if execution.activeSet != nil {
                        runningSet(item)
                    } else {
                        idle(item)
                    }
                }

                if let rest = execution.rest, rest.isOpen {
                    WatchRestBar(execution: execution, rest: rest)
                }

                Button {
                    Task { await execution.reconcileNow() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.footnote)
                }
                .accessibilityIdentifier("watch-refresh-exercise")

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
        .onAppear { prepare() }
        .onChange(of: execution.selectedItem?.orderIndex) { _, _ in prepare() }
        .onChange(of: loadKg) { _, value in execution.draftChanged(loadKg: value, reps: reps) }
        .onChange(of: reps) { _, value in execution.draftChanged(loadKg: loadKg, reps: value) }
        .sheet(isPresented: $showingRIR) { completionSheet }
        .sheet(isPresented: $showingForm) { formSheet }
    }

    // MARK: - Sections

    private func header(_ item: PrescriptionItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if execution.canLeaveExercise {
                    Button {
                        execution.backToList()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityIdentifier("watch-back-to-list")
                }
                Text(exerciseName(item))
                    .font(.headline)
                Spacer()
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
            }
            Text("Set \(setNumber(item)) of \(item.sets ?? 0)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(item.loadLabel) × \(item.repsLabel)")
                .font(.title3)
            Text(item.effortLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let heartRate = execution.heartRate {
                Text("\(heartRate) bpm")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func idle(_ item: PrescriptionItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            loadRow
            repsRow
            Button {
                execution.beginSet(loadKg: loadKg, reps: reps)
            } label: {
                Text("Start set").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("watch-start-set")

            if onLastPrescribedSet(item) {
                Button("Add set") {
                    execution.beginSet(loadKg: loadKg, reps: reps)
                }
                .font(.footnote)
                .accessibilityIdentifier("watch-add-set")
            }
            Button("End exercise") {
                if execution.completedSetCount(for: item) > 0 {
                    showingForm = true
                } else {
                    execution.doneWithExercise()
                }
            }
            .font(.footnote)
            .accessibilityIdentifier("watch-end-exercise")
        }
    }

    private func runningSet(_ item: PrescriptionItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Set time \(formattedDuration(execution.setDuration(at: context.date)))")
                    .font(.subheadline)
                    .monospacedDigit()
            }
            loadRow
            repsRow
            Button {
                showingRIR = true
            } label: {
                Text("End set").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(logging || execution.isWorking)
            .accessibilityIdentifier("watch-end-set")
        }
    }

    private var loadRow: some View {
        HStack {
            Text("\(formatted(loadKg)) kg").font(.body).monospacedDigit()
            Spacer()
            Button("−") { loadKg = max(0, loadKg - 2.5) }
            Button("+") { loadKg += 2.5 }
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

    private var completionSheet: some View {
        ScrollView {
            VStack(spacing: 4) {
                Text("Reps in reserve").font(.headline)
                Text("\(formatted(loadKg)) kg × \(reps)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("Bar speed m/s", text: $velocityText)
                    .accessibilityIdentifier("watch-velocity")
                if !velocityText.trimmingCharacters(in: .whitespaces).isEmpty,
                   parsedVelocity == nil {
                    Text("Speed must be a positive number.")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                ForEach(0...6, id: \.self) { value in
                    Button("\(value)") { save(rir: value) }
                }
                Button("Not recorded") { save(rir: nil) }
                Button("Cancel") { showingRIR = false }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var formSheet: some View {
        ScrollView {
            VStack(spacing: 4) {
                Text("Form rating").font(.headline)
                Text("How well did this exercise move?").font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(1...5, id: \.self) { value in
                    Button("\(value)") { saveForm(rating: value) }
                }
                Button("Skip") { endExercise() }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func saveForm(rating: Int) {
        showingForm = false
        let exerciseId = execution.selectedItem?.exerciseId ?? ""
        Task {
            await execution.rateForm(exerciseId: exerciseId, rating: rating)
            endExercise()
        }
    }

    private func endExercise() {
        showingForm = false
        execution.doneWithExercise()
    }

    // MARK: - Actions

    /// Optional mean velocity for the set (VBT). Empty means "not measured"; a non-empty value
    /// must parse, so a typo cannot silently drop the measurement.
    private var parsedVelocity: Double? {
        let trimmed = velocityText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let value = Double(trimmed), value > 0 else { return nil }
        return value
    }

    private func save(rir: Int?) {
        let trimmed = velocityText.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty || parsedVelocity != nil else { return }
        showingRIR = false
        logging = true
        let velocity = parsedVelocity
        Task {
            await execution.logSet(
                loadKg: loadKg,
                reps: reps,
                rir: rir,
                velocityMps: velocity
            )
            velocityText = ""
            logging = false
            prepare()
        }
    }

    private func prepare() {
        guard let item = execution.selectedItem else { return }
        let itemIndex = item.orderIndex ?? -1
        if let active = execution.activeSet, active.planItemIndex == itemIndex {
            loadKg = active.loadKg ?? loadKg
            reps = active.reps ?? reps
            preparedFor = "\(itemIndex)-draft"
            return
        }
        let key = "\(itemIndex)-\(item.exerciseId ?? "")"
        guard preparedFor != key else { return }
        preparedFor = key
        loadKg = item.loadKg ?? loadKg
        reps = item.repsLow ?? item.repsHigh ?? reps
    }

    // MARK: - Helpers

    private var banner: String {
        execution.isOffline
            ? "Offline · \(execution.pendingCount) pending"
            : "\(execution.pendingCount) pending"
    }

    private func onLastPrescribedSet(_ item: PrescriptionItem) -> Bool {
        execution.completedSetCount(for: item) >= max(0, (item.sets ?? 0) - 1)
    }

    private func setNumber(_ item: PrescriptionItem) -> Int {
        execution.completedSetCount(for: item) + 1
    }

    private func formattedDuration(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
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
}

struct WatchRestBar: View {
    @ObservedObject var execution: WatchExecutionController
    var rest: RestInterval

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 4) {
                if execution.restIsComplete(at: context.date) {
                    Text("Rest complete").font(.subheadline)
                } else {
                    let remaining = Int((execution.restRemaining(at: context.date) ?? 0).rounded(.up))
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
