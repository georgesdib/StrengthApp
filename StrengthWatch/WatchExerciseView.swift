import StrengthCore
import SwiftUI
import WatchKit

/// One exercise at a time: Start set → perform → End set (RIR) → rest → next set.
struct WatchExerciseView: View {
    @ObservedObject var execution: WatchExecutionController
    @Binding var showingSession: Bool
    @Binding var showingPlan: Bool

    @State private var loadKg = 0.0
    @State private var loadText = ""
    @State private var reps = 5
    @State private var showingRIR = false
    /// End-set stamp: the RIR/velocity entry that follows is rest time, not set time.
    @State private var completionStamp: Date?
    @State private var preparedFor: String?
    @State private var logging = false
    @State private var showingForm = false
    @State private var velocityText = ""
    @State private var repVelocityText = ""
    @State private var activeWarmup: ActiveWarmup?
    @State private var loggedWarmups: Set<Int> = []

    private struct ActiveWarmup: Equatable {
        let index: Int
        let loadKg: Double
        let reps: Int
        let startedAt: Date
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let item = execution.selectedItem {
                    header(item)
                    if let activeWarmup {
                        warmupRunning(activeWarmup)
                    } else if execution.activeSet != nil {
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
        .onChange(of: execution.selectedItem?.orderIndex) { _, _ in
            activeWarmup = nil
            loggedWarmups = []
            prepare()
        }
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
                .accessibilityIdentifier("watch-session")
            }
            Text("Set \(setNumber(item)) of \(item.sets ?? 0)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if let heartRate = execution.heartRate {
                    Label("\(heartRate) bpm", systemImage: "heart.fill")
                        .foregroundStyle(.red)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Label(
                        formattedDuration(execution.elapsed(at: context.date)),
                        systemImage: "timer"
                    )
                }
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("watch-total-time")
            }
            .font(.caption)
            .monospacedDigit()
            Text("\(item.loadLabel) × \(item.repsLabel)")
                .font(.title3)
            Text(item.effortLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let target = item.velocityTargetLabel {
                Text("target \(target)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("watch-target-velocity")
            }
        }
    }

    private func idle(_ item: PrescriptionItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            warmupSection(item)
            loadRow
            repsRow
            if loadEntryNeeded {
                Text("Enter the load for this exercise.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if prescribedSetsExhausted(item) {
                Button {
                    execution.beginSet(loadKg: loadKg, reps: reps)
                } label: {
                    Text("Add set").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("watch-add-set")
            } else {
                Button {
                    execution.beginSet(loadKg: loadKg, reps: reps)
                } label: {
                    Text("Start set").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("watch-start-set")
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

    private func warmupRunning(_ warmup: ActiveWarmup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Set time \(formattedDuration(context.date.timeIntervalSince(warmup.startedAt)))")
                    .font(.subheadline)
                    .monospacedDigit()
            }
            Text("\(formatted(warmup.loadKg)) kg × \(warmup.reps) · RIR 6")
                .font(.body)
                .monospacedDigit()
            Button {
                activeWarmup = nil
                loggedWarmups.insert(warmup.index)
                Task {
                    await execution.logWarmup(
                        loadKg: warmup.loadKg,
                        reps: warmup.reps,
                        index: warmup.index
                    )
                }
            } label: {
                Text("End set").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(logging || execution.isWorking)
            .accessibilityIdentifier("watch-end-warmup")
            Button("Cancel") { activeWarmup = nil }
                .font(.caption2)
                .foregroundStyle(.secondary)
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
                completionStamp = execution.currentStamp()
                showingRIR = true
            } label: {
                Text("End set").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(logging || execution.isWorking)
            .accessibilityIdentifier("watch-end-set")
        }
    }

    @ViewBuilder
    private func warmupSection(_ item: PrescriptionItem) -> some View {
        if let warmups = item.warmup, !warmups.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Warm-up")
                    .font(.caption)
                    .foregroundStyle(.orange)
                ForEach(Array(warmups.enumerated()), id: \.offset) { index, warmup in
                    HStack {
                        Text("Warm-up \(index + 1): \(warmup.loadLabel) × \(warmup.reps)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if loggedWarmups.contains(index) {
                            Label("Done", systemImage: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        } else {
                            Button("Start set") {
                                activeWarmup = ActiveWarmup(
                                    index: index,
                                    loadKg: warmup.loadKg,
                                    reps: warmup.reps,
                                    startedAt: Date()
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(execution.isWorking)
                            .accessibilityIdentifier("watch-log-warmup-\(index)")
                        }
                    }
                }
            }
            .accessibilityIdentifier("watch-warmups")
        }
    }

    private var loadRow: some View {
        HStack {
            Text("Load").font(.caption2)
            Spacer()
            TextField("kg", text: $loadText)
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier("watch-load")
        }
        .onChange(of: loadText) { _, text in
            let normalized = text.replacingOccurrences(of: ",", with: ".")
            if let value = Double(normalized) {
                loadKg = max(0, value)
            }
        }
    }

    private var repsRow: some View {
        HStack {
            Text(isTimeBased ? "\(reps) sec" : "\(reps) reps")
                .font(.body)
                .monospacedDigit()
            Spacer()
            Button("−") { reps = max(0, reps - (isTimeBased ? 5 : 1)) }
            Button("+") { reps += isTimeBased ? 5 : 1 }
        }
        .accessibilityIdentifier("watch-reps")
    }

    private var isTimeBased: Bool {
        execution.selectedItem?.isTimeBased == true
    }

    private var completionSheet: some View {
        ScrollView {
            VStack(spacing: 4) {
                Text("Reps in reserve").font(.headline)
                Text("\(formatted(loadKg)) kg × \(reps)\(isTimeBased ? "s" : "")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let target = execution.selectedItem?.velocityTargetLabel {
                    Text("Target \(target)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("watch-velocity-target")
                }
                // The watch records the measurement; the server supplies any target. Allow
                // it for external-load work even when the plan has no target, but not for
                // bodyweight work.
                if offersVelocityInput {
                    TextField("Bar speed m/s", text: $velocityText)
                        .accessibilityIdentifier("watch-velocity")
                    if !velocityText.trimmingCharacters(in: .whitespaces).isEmpty,
                       parsedVelocity == nil {
                        Text("Speed must be a positive number.")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                    TextField("Per-rep m/s", text: $repVelocityText)
                        .accessibilityIdentifier("watch-rep-velocity")
                    if let repVelocityError {
                        Text(repVelocityError)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                ForEach(0...6, id: \.self) { value in
                    Button("\(value)") { save(rir: value) }
                }
                Button("Not recorded") { save(rir: nil) }
                Button("Cancel") {
                    completionStamp = nil
                    showingRIR = false
                }
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
    /// A swapped or otherwise re-solved exercise has no issued target; allow an optional
    /// measurement for it, but keep bodyweight work free of a bar-speed prompt.
    private var offersVelocityInput: Bool {
        guard let item = execution.selectedItem else { return false }
        // The watch only records the measurement. A server target is optional; external-load
        // work can always be measured, while bodyweight work is not asked for bar speed.
        return !isBodyweight(item)
    }

    private func isBodyweight(_ item: PrescriptionItem) -> Bool {
        item.loadBasis == "bodyweight" || item.loadBasis == "bodyweight_total"
    }

    /// A nil load after a swap is unknown, not bodyweight. Force an explicit entry before the
    /// set can be started so a missing value is never recorded as 0 kg.
    private var loadEntryNeeded: Bool {
        guard let item = execution.selectedItem else { return false }
        return item.loadKg == nil
            && !isBodyweight(item)
            && loadKg <= 0
    }

    private var parsedVelocity: Double? {
        let trimmed = velocityText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let value = Double(trimmed), value > 0 else { return nil }
        return value
    }

    /// Per-rep velocities are optional, but a typo or too many values must not be dropped
    /// silently the way a rejected mean would be ignored.
    private var parsedRepVelocities: [RepVelocity]? {
        try? RepVelocityParser.parse(repVelocityText, reps: reps)
    }

    private var repVelocityError: String? {
        guard !repVelocityText.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        do {
            _ = try RepVelocityParser.parse(repVelocityText, reps: reps)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func save(rir: Int?) {
        let trimmed = velocityText.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty || parsedVelocity != nil else { return }
        guard repVelocityError == nil else { return }
        showingRIR = false
        logging = true
        let velocity = parsedVelocity
        let perRep = parsedRepVelocities
        let completedAt = completionStamp
        completionStamp = nil
        Task {
            await execution.logSet(
                loadKg: loadKg,
                reps: reps,
                rir: rir,
                velocityMps: velocity,
                repVelocities: perRep,
                completedAt: completedAt
            )
            velocityText = ""
            repVelocityText = ""
            logging = false
            prepare()
        }
    }

    private func prepare() {
        guard let item = execution.selectedItem else { return }
        let itemIndex = item.orderIndex ?? -1
        if let active = execution.activeSet, active.planItemIndex == itemIndex {
            loadKg = active.loadKg ?? loadKg
            loadText = formatted(loadKg)
            reps = active.reps ?? reps
            preparedFor = "\(itemIndex)-draft"
            return
        }
        let key = "\(itemIndex)-\(item.exerciseId ?? "")"
        guard preparedFor != key else { return }
        preparedFor = key
        if let plannedLoad = item.loadKg {
            loadKg = plannedLoad
            loadText = formatted(plannedLoad)
        } else {
            loadKg = 0
            loadText = ""
        }
        reps = item.repsLow ?? item.repsHigh ?? reps
    }

    // MARK: - Helpers

    private var banner: String {
        execution.isOffline
            ? "Offline · \(execution.pendingCount) pending"
            : "\(execution.pendingCount) pending"
    }

    /// True once every prescribed set is done, so the only remaining action is an extra set.
    private func prescribedSetsExhausted(_ item: PrescriptionItem) -> Bool {
        execution.completedSetCount(for: item) >= max(0, item.sets ?? 0)
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
    @State private var announced = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let complete = execution.restIsComplete(at: context.date)
            VStack(alignment: .leading, spacing: 4) {
                if complete {
                    Text("Rest complete").font(.subheadline)
                } else {
                    let remaining = Int((execution.restRemaining(at: context.date) ?? 0).rounded(.up))
                    Text("Rest \(remaining / 60):\(String(format: "%02d", remaining % 60))")
                        .font(.subheadline)
                        .monospacedDigit()
                }
                HStack {
                    Button("+15s") { execution.extendRest(by: 15) }
                    Button("−15s") { execution.shortenRest(by: 15) }
                }
                .font(.caption2)
            }
            // The timer is a local clock; buzz the wrist the moment it reaches zero.
            .onChange(of: complete) { _, isComplete in
                if isComplete, !announced {
                    announced = true
                    WKInterfaceDevice.current().play(.notification)
                } else if !isComplete {
                    announced = false
                }
            }
        }
    }
}
