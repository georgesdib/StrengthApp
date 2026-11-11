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
    @State private var addOperation = OperationKey<AddSetRequest>()
    @State private var addError: String?
    @State private var pendingRemoval: WorkoutSet?
    @State private var removeError: String?
    @State private var rating = 4
    @State private var formOperation = OperationKey<FormRatingRequest>()
    @State private var formError: String?
    @State private var activeLocalSetID: String?
    @State private var recordedExerciseStart = false
    @State private var recordedExerciseCompletion = false

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
                    LabeledContent("Target", value: "\(item.sets ?? 0) × \(item.repsLabel) · \(item.loadLabel) · \(item.effortLabel)")
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
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(warmupTitle(index: index, warmup: warmup))
                                    .font(.subheadline)
                                Text("\(warmup.reps) reps @ \(warmup.loadLabel)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .accessibilityIdentifier("warmup-\(index)")
                    }
                    Text("Optional. Log the working sets; skipping a warm-up does not block them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Form rating") {
                if let existing = workout?.formRating(for: exerciseId) {
                    LabeledContent("Current rating", value: "\(existing.rating) / 5")
                        .accessibilityIdentifier("exercise-form-current")
                    Text("Saving again records a correction. The earlier rating is retained; the latest is shown here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Picker("Rating", selection: $rating) {
                    ForEach(1...5, id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("exercise-form-rating")
                if let formError {
                    Text(formError).foregroundStyle(.red)
                }
                Button {
                    Task { await saveForm() }
                } label: {
                    HStack {
                        Spacer()
                        if model.isSaving {
                            ProgressView()
                        } else {
                            Text(workout?.formRating(for: exerciseId) == nil
                                 ? "Save form rating" : "Save correction")
                        }
                        Spacer()
                    }
                }
                .accessibilityIdentifier("exercise-save-form")
                .disabled(model.isSaving)
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
                                    Text("Target \(item?.repsLabel ?? "—") · \(item?.loadLabel ?? "—") · \(item?.effortLabel ?? "—")")
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
                .disabled(model.isSaving)
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
            rating = workout?.formRating(for: exerciseId)?.rating ?? 4
            if !recordedExerciseStart {
                recordedExerciseStart = true
                recordExerciseEvent(.exerciseStarted)
            }
        }
        .onDisappear {
            if !recordedExerciseCompletion {
                recordedExerciseCompletion = true
                recordExerciseEvent(.exerciseCompleted)
            }
        }
        .sheet(isPresented: $showingLog) {
            LogSetSheet(
                draft: draft,
                exerciseLabel: Self.label(exerciseId),
                target: logSetIndex.map { "Planned set \($0)" },
                isSaving: model.isSaving,
                error: addError
            ) {
                Task { await saveSet() }
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

    private func beginLog(planSetIndex: Int?) {
        addError = nil
        if model.restTimer.startedAt != nil {
            model.interruptRest()
        }
        let localSetID = UUID().uuidString.lowercased()
        activeLocalSetID = localSetID
        let setIndex = planSetIndex ?? (performed.compactMap(\.setIndex).max() ?? 0) + 1
        recordExecutionEvent(ExecutionEvent(
            eventType: .setStarted,
            planItemIndex: planIdentity,
            localSetId: localSetID,
            payload: [
                "set_index": .number(Double(setIndex)),
                "exercise_id": .string(exerciseId),
            ]
        ))
        logSetIndex = planSetIndex
        if planSetIndex != nil {
            drafts.drafts[draftKey] = WorkoutDraftStore.Draft(
                loadText: item?.loadKg.map { String(format: "%.1f", $0) } ?? "",
                repsText: item?.repsLow.map(String.init) ?? "",
                rirText: item?.rirTarget.map(String.init) ?? "",
                velocityText: "",
                repVelocityText: "",
                showingRepVelocity: false
            )
        } else if drafts.drafts[draftKey] == nil {
            drafts.drafts[draftKey] = initialDraft
        }
        showingLog = true
    }

    private func saveSet() async {
        addError = nil
        let draft = draft.wrappedValue
        guard let reps = Int(draft.repsText.trimmingCharacters(in: .whitespaces)) else {
            addError = "Reps are required."
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
        let setIndex = logSetIndex ?? (performed.compactMap(\.setIndex).max() ?? 0) + 1
        let localSetID = activeLocalSetID
        let completedAt = ExecutionEvent.nowISO()
        let request = AddSetRequest(
            exerciseId: exerciseId,
            loadKg: load,
            reps: reps,
            rir: rir,
            velocityMps: velocity,
            setIndex: setIndex,
            planItemIndex: planIdentity,
            repVelocities: repVelocities
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
            if rir != 6 {
                let prescribed = item?.restS ?? 120
                model.startRest(
                    seconds: prescribed,
                    planItemIndex: planIdentity,
                    exerciseId: exerciseId
                )
            }
            showingLog = false
        } else {
            addError = model.mutationError
        }
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

    private func saveForm() async {
        formError = nil
        let request = FormRatingRequest(
            exerciseId: exerciseId,
            rating: rating,
            note: nil
        )
        let key = formOperation.use(request)
        if await model.rateForm(request, idempotencyKey: key) {
            formOperation.acknowledged()
        } else {
            formError = model.mutationError
        }
    }

    private func recordExerciseEvent(_ type: ExecutionEventType) {
        recordExecutionEvent(ExecutionEvent(
            eventType: type,
            planItemIndex: planIdentity,
            payload: ["exercise_id": .string(exerciseId)]
        ))
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

    private static func label(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private struct LogSetSheet: View {
    @Binding var draft: WorkoutDraftStore.Draft
    let exerciseLabel: String
    let target: String?
    let isSaving: Bool
    let error: String?
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

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
                    LabeledContent("Reps") {
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onSave() }
                        .accessibilityIdentifier("save-set")
                        .disabled(isSaving)
                }
            }
        }
    }
}
