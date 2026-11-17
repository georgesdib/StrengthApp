import SwiftUI
import StrengthCore

struct ExerciseWorkoutView: View {
    @ObservedObject var model: AppModel
    let exerciseId: String
    let planIndex: Int?
    @ObservedObject var drafts: WorkoutDraftStore

    @Environment(\.dismiss) private var dismiss
    @State private var showingLog = false
    @State private var logSetIndex: Int?
    @State private var logWarmupLabel: String?
    @State private var addOperation = OperationKey<AddSetRequest>()
    @State private var addError: String?
    @State private var pendingRemoval: WorkoutSet?
    @State private var removeError: String?
    @State private var activeLocalSetID: String?
    @State private var showingEndExercise = false
    @State private var endError: String?

    private var workout: WorkoutDetail? { model.activeWorkout }

    private var item: PrescriptionItem? {
        guard let workout, let planIndex,
              let items = workout.plan?.items,
              items.indices.contains(planIndex) else { return nil }
        return items[planIndex]
    }

    private var planIdentity: Int? {
        guard let item else { return nil }
        return item.orderIndex ?? planIndex
    }

    private var plannedSets: Int { item?.sets ?? 0 }

    private var isExerciseActive: Bool {
        model.isExerciseActive(planItemIndex: planIdentity, exerciseId: exerciseId)
    }

    private var activeExercise: ActiveExercise? {
        model.activeExercises.first {
            $0.key == ActiveExercise.key(planItemIndex: planIdentity, exerciseId: exerciseId)
        }
    }

    private var performed: [WorkoutSet] {
        (workout?.sets ?? []).filter { $0.exerciseId == exerciseId }
    }

    private var draftKey: String {
        drafts.key(exerciseId: exerciseId, planIndex: planIndex)
    }

    private var draft: Binding<WorkoutDraftStore.Draft> {
        Binding(
            get: { drafts.drafts[draftKey] ?? initialDraft },
            set: { drafts.drafts[draftKey] = $0 }
        )
    }

    private var initialDraft: WorkoutDraftStore.Draft {
        WorkoutDraftStore.Draft(
            loadText: item?.loadKg.map { String(format: "%.1f", $0) } ?? "",
            repsText: item?.repsLow.map(String.init) ?? "",
            rirText: item?.rirTarget.map(String.init) ?? "",
            velocityText: "",
            repVelocityText: "",
            showingRepVelocity: false
        )
    }

    var body: some View {
        Form {
            if model.offlineCaptureActive {
                Section {
                    Label(
                        model.isOffline ? "Offline — sets are saved on this phone" : "Pending server acknowledgement",
                        systemImage: model.isOffline ? "wifi.slash" : "clock.arrow.circlepath"
                    )
                    .foregroundStyle(.orange)
                }
            }

            Section("Exercise") {
                LabeledContent("Exercise", value: Self.label(exerciseId))
                if let item {
                    LabeledContent("Target", value: "\(item.sets ?? 0) × \(item.repsLabel) · \(item.loadLabel) · \(item.effortLabel)\(item.velocityTargetLabel.map { " · target \($0)" } ?? "")")
                        .accessibilityIdentifier("exercise-target")
                    LabeledContent("Rest", value: "\(item.restS ?? 120)s")
                } else {
                    Text("Not in the prescription. Sets are still recorded as performed work.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let last = performed.last {
                    LabeledContent("Last set", value: last.summary)
                }
            }

            if let warmups = item?.warmup, !warmups.isEmpty {
                Section("Warm-ups") {
                    ForEach(Array(warmups.enumerated()), id: \.offset) { index, warmup in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(warmupTitle(index: index, warmup: warmup))
                                    .font(.headline)
                                Text("\(warmup.reps) reps @ \(warmup.loadLabel) · RIR 6")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Start set") {
                                beginWarmup(index: index, warmup: warmup)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .accessibilityIdentifier("log-warmup-\(index)")
                            .disabled(model.isMirroringWatchSession)
                        }
                        .accessibilityIdentifier("warmup-\(index)")
                    }
                    Text("Optional. A warm-up is an ordinary set logged with RIR 6; it does not start the rest timer.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if model.isMirroringWatchSession {
                Section("Logged on Apple Watch") {
                    Label(
                        "Form ratings are recorded on the Apple Watch.",
                        systemImage: "applewatch"
                    )
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("mirror-form-disabled")
                    Text("Take over logging to log or end exercises here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if let active = activeExercise {
                Section("In progress") {
                    TimelineView(.periodic(from: active.startedAt, by: 1)) { context in
                        LabeledContent(
                            "Exercise time",
                            value: Self.durationLabel(
                                context.date.timeIntervalSince(active.startedAt)
                            )
                        )
                        .monospacedDigit()
                    }
                    Button("End exercise") { showingEndExercise = true }
                        .accessibilityIdentifier("end-exercise")
                    if let endError {
                        Text(endError).foregroundStyle(.red)
                    }
                }
            } else {
                Section {
                    Text("The first set starts this exercise and it stays open until you end it. Starting a set in another exercise is a superset.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if plannedSets > 0 {
                Section("Planned sets") {
                    ForEach(1...plannedSets, id: \.self) { index in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Set \(index)")
                                    .font(.headline)
                                if let set = performedSet(at: index) {
                                    Text(set.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Target \(item?.repsLabel ?? "—") · \(item?.loadLabel ?? "—") · \(item?.effortLabel ?? "—")\(item?.velocityTargetLabel.map { " · target \($0)" } ?? "")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if performedSet(at: index) != nil {
                                Label("Done", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else {
                                Button("Start set") {
                                    beginLog(planSetIndex: index)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .accessibilityIdentifier("log-planned-set-\(index)")
                                .disabled(model.isMirroringWatchSession)
                            }
                        }
                    }
                }
            }

            Section("Logged sets") {
                if performed.isEmpty {
                    Text("No performed sets yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(performed) { set in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(set.summary)
                                    .font(.subheadline)
                                Spacer()
                                if set.isPendingLocal {
                                    Text("Pending")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                            if let summary = set.repSummary {
                                Text("Per-rep \(summary.count) · \(String(format: "%.2f", summary.first)) → \(String(format: "%.2f", summary.last)) m/s")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Button("Remove set", role: .destructive) {
                                pendingRemoval = set
                            }
                            .font(.caption)
                        }
                    }
                }
                if let removeError {
                    Text(removeError).foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    beginLog(planSetIndex: nil)
                } label: {
                    Label("Start another set", systemImage: "plus")
                }
                .accessibilityIdentifier("exercise-add-set")
                .disabled(model.isSaving || model.isMirroringWatchSession)
            }

            Section {
                Text("A working set starts the rest timer using this exercise's prescribed rest. Warm-up sets (RIR 6) do not.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(Self.label(exerciseId))
        .onAppear {
            if drafts.drafts[draftKey] == nil {
                drafts.drafts[draftKey] = initialDraft
            }
        }
        .sheet(isPresented: $showingEndExercise) {
            EndExerciseSheet(
                exerciseLabel: Self.label(exerciseId),
                canRateForm: planIdentity != nil,
                isSaving: model.isSaving
            ) { rating in
                Task { await endExercise(rating: rating) }
            }
        }
        .sheet(isPresented: $showingLog) {
            LogSetSheet(
                draft: draft,
                exerciseLabel: Self.label(exerciseId),
                target: logWarmupLabel ?? logSetIndex.map { "Planned set \($0)" },
                velocityTarget: item?.velocityTargetLabel,
                isTimeBased: item?.isTimeBased == true,
                velocityApplicable: item?.loadBasis != "bodyweight"
                    && item?.loadBasis != "bodyweight_total",
                isSaving: model.isSaving,
                error: addError
            ) { anchor in
                Task { await saveSet(performedAt: anchor) }
            }
        }
        .alert(item: $pendingRemoval) { set in
            Alert(
                title: Text("Remove this set?"),
                message: Text("The performed set will be removed from this workout."),
                primaryButton: .destructive(Text("Remove")) {
                    Task { await remove(set) }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func performedSet(at index: Int) -> WorkoutSet? {
        performed.first {
            $0.setIndex == index && $0.planItemIndex == planIdentity
        }
    }

    /// A warm-up is an ordinary set with RIR 6 prefilled: the same Start set, the same sheet and
    /// the same events. Nothing about the set is special until the RIR is entered.
    private func beginWarmup(index: Int, warmup: WarmupSet) {
        let draft = WorkoutDraftStore.Draft(
            loadText: String(format: "%.1f", warmup.loadKg),
            repsText: String(warmup.reps),
            rirText: "6",
            velocityText: "",
            repVelocityText: "",
            showingRepVelocity: false
        )
        startSet(plannedIndex: nil, label: "Warm-up \(index + 1)", draft: draft)
    }

    private func beginLog(planSetIndex: Int?) {
        let draft: WorkoutDraftStore.Draft
        if planSetIndex != nil {
            draft = WorkoutDraftStore.Draft(
                loadText: item?.loadKg.map { String(format: "%.1f", $0) } ?? "",
                repsText: item?.repsLow.map(String.init) ?? "",
                rirText: item?.rirTarget.map(String.init) ?? "",
                velocityText: "",
                repVelocityText: "",
                showingRepVelocity: false
            )
        } else {
            draft = drafts.drafts[draftKey] ?? initialDraft
        }
        startSet(
            plannedIndex: planSetIndex,
            label: planSetIndex.map { "Planned set \($0)" },
            draft: draft
        )
    }

    /// The first set starts the exercise, whatever its RIR. The set's index is not fixed here:
    /// RIR 6 is only known at save time and decides which index range the set belongs to.
    private func startSet(
        plannedIndex: Int?,
        label: String?,
        draft: WorkoutDraftStore.Draft
    ) {
        addError = nil
        if model.restTimer.startedAt != nil {
            model.interruptRest()
        }
        let localSetID = UUID().uuidString.lowercased()
        activeLocalSetID = localSetID
        model.startExercise(planItemIndex: planIdentity, exerciseId: exerciseId)
        recordExecutionEvent(ExecutionEvent(
            eventType: .setStarted,
            planItemIndex: planIdentity,
            localSetId: localSetID,
            payload: ["exercise_id": .string(exerciseId)]
        ))
        logSetIndex = plannedIndex
        logWarmupLabel = label
        drafts.drafts[draftKey] = draft
        showingLog = true
    }

    /// `performedAt` is the first edit of the sheet: the set ended then, and the rest is
    /// anchored there so the entry itself is rest rather than part of the set.
    private func saveSet(performedAt anchor: Date) async {
        addError = nil
        let draft = draft.wrappedValue
        guard let reps = Int(draft.repsText.trimmingCharacters(in: .whitespaces)) else {
            addError = item?.isTimeBased == true ? "Seconds are required." : "Reps are required."
            return
        }
        let load = parseDouble(draft.loadText)
        if !draft.loadText.trimmingCharacters(in: .whitespaces).isEmpty, load == nil {
            addError = "Load must be a number."
            return
        }
        let rir = parseInt(draft.rirText)
        if !draft.rirText.trimmingCharacters(in: .whitespaces).isEmpty, rir == nil {
            addError = "RIR must be a whole number."
            return
        }
        let velocity = parseDouble(draft.velocityText)
        if !draft.velocityText.trimmingCharacters(in: .whitespaces).isEmpty,
           (velocity ?? 0) <= 0 {
            addError = "Velocity must be a positive number."
            return
        }
        let repVelocities: [RepVelocity]?
        do {
            repVelocities = try RepVelocityParser.parse(draft.repVelocityText, reps: reps)
        } catch {
            addError = error.localizedDescription
            return
        }
        let setIndex = resolvedSetIndex(rir: rir)
        let localSetID = activeLocalSetID
        let completedAt = ServerClock.encodedISO(anchor)
        let request = AddSetRequest(
            exerciseId: exerciseId,
            loadKg: load,
            reps: reps,
            rir: rir,
            velocityMps: velocity,
            setIndex: setIndex,
            planItemIndex: planIdentity,
            repVelocities: repVelocities,
            performedAt: completedAt
        )
        let key = addOperation.use(request)
        if await model.addSet(request, idempotencyKey: key) {
            addOperation.acknowledged()
            let savedSet = (model.activeWorkout?.sets ?? []).last {
                $0.exerciseId == exerciseId
                    && $0.setIndex == setIndex
                    && $0.planItemIndex == planIdentity
            }
            recordExecutionEvent(ExecutionEvent(
                eventType: .setCompleted,
                occurredAt: completedAt,
                planItemIndex: planIdentity,
                setId: savedSet?.setId.flatMap { $0 > 0 ? $0 : nil },
                localSetId: localSetID,
                payload: [
                    "set_index": .number(Double(setIndex)),
                    "exercise_id": .string(exerciseId),
                ]
            ))
            activeLocalSetID = nil
            logWarmupLabel = nil
            if rir != 6 {
                let prescribed = item?.restS ?? 120
                model.startRest(
                    seconds: prescribed,
                    planItemIndex: planIdentity,
                    exerciseId: exerciseId,
                    startedAt: anchor
                )
            }
            showingLog = false
        } else {
            addError = model.mutationError
        }
    }

    /// RIR 6 sends the set above the planned range so it never takes a planned slot; a planned
    /// row keeps its own index; anything else takes the next free index. Deciding here rather
    /// than at Start set is what makes RIR 6 the only warm-up marker.
    private func resolvedSetIndex(rir: Int?) -> Int {
        if rir == 6 {
            return 1000 + performed.filter { $0.rir == 6 }.count
        }
        if let planned = logSetIndex { return planned }
        return Self.nextUnplannedSetIndex(
            planned: item?.sets ?? 0,
            existing: performed.compactMap(\.setIndex)
        )
    }

    private func endExercise(rating: Int?) async {
        endError = nil
        if let rating, planIdentity != nil {
            let request = FormRatingRequest(exerciseId: exerciseId, rating: rating, note: nil)
            let saved = await model.rateForm(
                request,
                idempotencyKey: UUID().uuidString.lowercased()
            )
            if !saved {
                endError = model.mutationError ?? "The form rating could not be saved."
                return
            }
        }
        showingEndExercise = false
        model.endExercise(planItemIndex: planIdentity, exerciseId: exerciseId)
        dismiss()
    }

    private static func durationLabel(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func remove(_ set: WorkoutSet) async {
        removeError = nil
        guard let workout else { return }
        guard let setId = set.setId else { return }
        let ok: Bool
        if setId < 0 {
            ok = await model.cancelOfflineSet(localSetId: setId)
        } else {
            ok = await model.removeSet(
                workoutId: workout.workoutId,
                setId: setId,
                idempotencyKey: UUID().uuidString.lowercased()
            )
        }
        if !ok {
            removeError = model.mutationError
        }
    }

    private func warmupTitle(index: Int, warmup: WarmupSet) -> String {
        if index == 0, warmup.loadKg == 20 {
            return "Empty bar"
        }
        return "Warm-up \(index + 1)"
    }

    private func recordExecutionEvent(_ event: ExecutionEvent) {
        model.recordExecutionEvent(event)
    }

    private func parseDouble(_ text: String) -> Double? {
        let value = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        return value.isEmpty ? nil : Double(value)
    }

    private func parseInt(_ text: String) -> Int? {
        let value = text.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : Int(value)
    }

    /// Unplanned and warm-up sets sit above the whole planned range. A plain max+1 can collide
    /// with a later planned set (or a warm-up logged first), and the server treats a repeated
    /// index as a retry, so the working set would never be recorded.
    nonisolated static func nextUnplannedSetIndex(planned: Int, existing: [Int]) -> Int {
        max(planned, existing.max() ?? 0) + 1
    }

    private static func label(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private struct LogSetSheet: View {
    @Binding var draft: WorkoutDraftStore.Draft
    let exerciseLabel: String
    let target: String?
    /// The server's prescribed bar speed, shown beside RIR; nil when no target was issued.
    let velocityTarget: String?
    let isTimeBased: Bool
    let velocityApplicable: Bool
    let isSaving: Bool
    let error: String?
    /// The set ended when the first field changed; `Date` is that stamp (fallback: sheet open).
    let onSave: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var anchor: Date?
    @State private var openedAt = Date()

    private func markAnchorIfNeeded() {
        guard anchor == nil else { return }
        anchor = Date()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let target {
                        Text(target)
                            .font(.headline)
                    }
                    LabeledContent("Load (kg)") {
                        TextField("optional", text: $draft.loadText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("set-load")
                    }
                    LabeledContent(isTimeBased ? "Seconds" : "Reps") {
                        TextField("required", text: $draft.repsText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("set-reps")
                    }
                    LabeledContent("RIR") {
                        TextField("0-6", text: $draft.rirText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("set-rir")
                    }
                    if let velocityTarget {
                        LabeledContent("Velocity target", value: velocityTarget)
                            .accessibilityIdentifier("set-velocity-target")
                    }
                    if velocityApplicable {
                        LabeledContent("Mean velocity (m/s)") {
                            TextField("optional", text: $draft.velocityText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .accessibilityIdentifier("set-velocity")
                        }
                        DisclosureGroup(
                            "Per-rep velocity (optional)",
                            isExpanded: $draft.showingRepVelocity
                        ) {
                            TextField("e.g. 0.62, 0.58, 0.55", text: $draft.repVelocityText)
                                .keyboardType(.numbersAndPunctuation)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                } header: {
                    Text(exerciseLabel)
                } footer: {
                    Text("Warm-up sets use RIR 6 and do not start the rest timer.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Log set")
            // First edit is the End-set moment: reaching for the phone to record the set.
            .onChange(of: draft.loadText) { markAnchorIfNeeded() }
            .onChange(of: draft.repsText) { markAnchorIfNeeded() }
            .onChange(of: draft.rirText) { markAnchorIfNeeded() }
            .onChange(of: draft.velocityText) { markAnchorIfNeeded() }
            .onChange(of: draft.repVelocityText) { markAnchorIfNeeded() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onSave(anchor ?? openedAt) }
                        .accessibilityIdentifier("save-set")
                        .disabled(isSaving)
                }
            }
        }
    }
}

/// Ending an exercise is the deliberate action that records its completion, so the optional form
/// rating belongs here rather than in a section that can be saved at any time.
private struct EndExerciseSheet: View {
    let exerciseLabel: String
    let canRateForm: Bool
    let isSaving: Bool
    let onFinish: (Int?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Ending closes any running rest and records that the exercise finished.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if canRateForm {
                    Section("Form rating") {
                        Text("Optional. How well did this exercise move?")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ForEach(1...5, id: \.self) { value in
                            Button("\(value) / 5") { onFinish(value) }
                                .accessibilityIdentifier("end-exercise-form-\(value)")
                        }
                    }
                }
                Section {
                    Button(canRateForm ? "Skip rating and end" : "End exercise") {
                        onFinish(nil)
                    }
                    .accessibilityIdentifier("end-exercise-confirm")
                }
            }
            .navigationTitle("End \(exerciseLabel)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .disabled(isSaving)
        }
    }
}
