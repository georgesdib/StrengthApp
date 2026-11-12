import SwiftUI
import UIKit
import StrengthCore

struct ActiveWorkoutView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var exerciseId = ""
    @State private var selectedPlanItemIndex: Int?
    @State private var loadText = ""
    @State private var repsText = ""
    @State private var rirText = ""
    @State private var velocityText = ""
    @State private var showingRepVelocity = false
    @State private var repVelocityText = ""
    @State private var addOperation = OperationKey<AddSetRequest>()
    @State private var addError: String?

    @State private var ratingExercise = ""
    @State private var rating = 4
    @State private var formOperation = OperationKey<FormRatingRequest>()
    @State private var formError: String?

    @State private var rpe: Int? = 7
    @State private var productivity: Int? = nil
    @State private var durationText = ""
    @State private var notes = ""
    @State private var finishOperation = OperationKey<CompleteWorkoutRequest>()
    @State private var finishLocked = false
    @State private var finishError: String?

    @State private var abandonKey = UUID().uuidString.lowercased()
    @State private var confirmingAbandon = false
    @State private var abandonError: String?
    @State private var planPicker: PlanPickerMode?
    @State private var pendingRemoval: PlanRemoval?
    @State private var planEditError: String?
    @State private var confirmingTakeOver = false
    @State private var takeOverError: String?
    @StateObject private var drafts = WorkoutDraftStore()
    @State private var otherExerciseId: String?
    @State private var showingOtherExercisePicker = false

    private var workout: WorkoutDetail? { model.activeWorkout }

    private var exerciseOptions: [String] {
        guard let workout else { return [] }
        let planned = (workout.plan?.items ?? []).compactMap(\.exerciseId)
        let logged = (workout.sets ?? []).map(\.exerciseId)
        return Array(Set(planned + logged)).sorted()
    }

    private var planChoices: [PlanItemChoice] {
        workout?.plan?.choices(for: exerciseId) ?? []
    }

    var body: some View {
        Group {
                if let workout {
                    Form {
                        if model.offlineCaptureActive {
                            Section("Offline capture") {
                                Label(
                                    model.isOffline ? "Offline — saved on this phone" : "Pending server acknowledgement",
                                    systemImage: model.isOffline ? "wifi.slash" : "clock.arrow.circlepath"
                                )
                                .foregroundStyle(.orange)
                                Text("\(model.pendingOfflineCount) queued operation\(model.pendingOfflineCount == 1 ? "" : "s"). These are not server-confirmed yet.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                if let error = model.offlineSyncError {
                                    Text(error).font(.caption).foregroundStyle(.red)
                                }
                                if model.isSyncingOffline {
                                    HStack { ProgressView(); Text("Syncing…") }
                                } else {
                                    Button("Sync now") {
                                        Task { await model.syncOfflineCapture() }
                                    }
                                }
                            }
                        }

                        if let error = model.offlinePersistenceError {
                            Section("Offline capture write failed") {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        if let error = model.offlineTelemetryError {
                            Section("Execution timing") {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }

                        Section("Workout") {
                            LabeledContent("Session", value: Self.label(workout.sessionType ?? "workout"))
                            LabeledContent("Date", value: workout.forDate ?? "—")
                            LabeledContent("Status", value: Self.label(workout.status))
                            if let elapsed = workout.elapsedSeconds {
                                LabeledContent("Elapsed", value: Self.durationLabel(elapsed))
                            }
                        }

                        if model.isMirroringWatchSession {
                            Section("Logged on Apple Watch") {
                                Label(
                                    "This session is logged on the Apple Watch.",
                                    systemImage: "applewatch"
                                )
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("mirror-banner")
                                Text("Sets are recorded on the watch. Plan edits here reach it at the next idle point, never mid-set.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                if let takeOverError {
                                    Text(takeOverError)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                        .accessibilityIdentifier("take-over-error")
                                }
                                Button {
                                    confirmingTakeOver = true
                                } label: {
                                    HStack {
                                        Spacer()
                                        if model.isSaving {
                                            ProgressView()
                                        } else {
                                            Text("Take over logging")
                                        }
                                        Spacer()
                                    }
                                }
                                .disabled(model.isSaving)
                                .accessibilityIdentifier("take-over-logging")
                            }
                        }

                        Section {
                            let planItems = workout.plan?.items ?? []
                            ForEach(Array(planItems.enumerated()), id: \.offset) { index, item in
                                let exercise = item.exerciseId ?? ""
                                let identity = item.orderIndex ?? index
                                let setState = planSetState(identity: identity, exerciseId: exercise)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(Self.label(exercise.isEmpty ? "exercise" : exercise))
                                            .font(.headline)
                                        Spacer()
                                        if let sets = item.sets {
                                            Text("\(sets) sets")
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                        }
                                        Menu {
                                            Button("Swap exercise") {
                                                planPicker = .swap(index: index)
                                            }
                                            .disabled(setState.logged > 0 || exercise.isEmpty)
                                            Button("Remove exercise", role: .destructive) {
                                                pendingRemoval = PlanRemoval(
                                                    index: index,
                                                    exerciseId: exercise,
                                                    label: Self.label(exercise)
                                                )
                                            }
                                            .disabled(planItems.count == 1 || exercise.isEmpty)
                                            Divider()
                                            Button("Add one set") {
                                                Task {
                                                    await changeSets(
                                                        workout: workout,
                                                        index: index,
                                                        delta: 1,
                                                        exerciseId: exercise
                                                    )
                                                }
                                            }
                                            .disabled(model.isSaving || (item.sets ?? 1) >= 20)
                                            Button("Remove one set") {
                                                Task {
                                                    await changeSets(
                                                        workout: workout,
                                                        index: index,
                                                        delta: -1,
                                                        exerciseId: exercise
                                                    )
                                                }
                                            }
                                            .disabled(model.isSaving || !canDecrease(
                                                item: item,
                                                state: setState
                                            ))
                                        } label: {
                                            Image(systemName: "ellipsis.circle")
                                                .accessibilityLabel("Plan options")
                                        }
                                        .disabled(model.isSaving)
                                    }
                                    HStack(spacing: 8) {
                                        Text(item.repsLabel)
                                        Text(item.loadLabel)
                                        Text(item.effortLabel)
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    if setState.logged > 0 {
                                        Text("Swap is unavailable after sets are logged.")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    NavigationLink {
                                        ExerciseWorkoutView(
                                            model: model,
                                            exerciseId: exercise,
                                            planIndex: index,
                                            drafts: drafts
                                        )
                                    } label: {
                                        Label("Open sets", systemImage: "list.bullet")
                                            .font(.caption)
                                    }
                                    .accessibilityIdentifier("open-exercise-\(index)")
                                }
                                .padding(.vertical, 2)
                            }
                            if let planEditError {
                                Text(planEditError)
                                    .foregroundStyle(.red)
                                    .accessibilityIdentifier("plan-edit-error")
                            }
                        } header: {
                            HStack {
                                Text("Plan")
                                Spacer()
                                Button {
                                    planPicker = .add
                                } label: {
                                    Label("Add", systemImage: "plus")
                                }
                                .accessibilityIdentifier("add-plan-exercise")
                                .disabled(model.isSaving)
                            }
                        }

                        Section("Outside the plan") {
                            Button {
                                showingOtherExercisePicker = true
                            } label: {
                                Label("Log an exercise not in the plan", systemImage: "plus.circle")
                            }
                            .disabled(model.isSaving || model.isMirroringWatchSession)
                            .accessibilityIdentifier("log-outside-exercise")
                            Text("The set is recorded as performed work without changing the prescription.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        Section("Logged sets") {
                            let sets = workout.sets ?? []
                            if sets.isEmpty {
                                Text("No sets logged yet.")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(sets) { set in
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(Self.label(set.exerciseId))
                                                .font(.subheadline)
                                            Spacer()
                                            Text(set.loadLabel)
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                        }
                                        HStack(spacing: 8) {
                                            Text("\(set.reps ?? 0) reps")
                                            if let rir = set.rir {
                                                Text("RIR \(rir)")
                                            }
                                            if let velocity = set.velocityLabel {
                                                Text(velocity)
                                            }
                                            if set.isPendingLocal {
                                                Text("Pending")
                                                    .foregroundStyle(.orange)
                                            }
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        if set.isPendingLocal, let localId = set.setId {
                                            Button("Remove pending set", role: .destructive) {
                                                Task { await removePendingSet(localId) }
                                            }
                                            .font(.caption)
                                            .disabled(model.isSaving)
                                        }
                                        if let summary = set.repSummary {
                                            Text("Per-rep \(summary.count) reps · \(String(format: "%.2f", summary.first)) → \(String(format: "%.2f", summary.last)) m/s · loss \(String(format: "%.2f", summary.lossAbs)) m/s")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        if let detail = set.repsDetail, !detail.reps.isEmpty {
                                            DisclosureGroup("Rep velocities") {
                                                ForEach(detail.reps) { rep in
                                                    Text("Rep \(rep.repIndex): \(String(format: "%.2f", rep.velocityMps)) m/s")
                                                        .font(.caption)
                                                }
                                            }
                                            .font(.caption)
                                        }
                                    }
                                }
                            }
                            if let forms = workout.forms, !forms.isEmpty {
                                ForEach(forms) { form in
                                    Text("\(Self.label(form.exerciseId)): form \(form.rating)/5")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Section("Form rating") {
                            if model.isMirroringWatchSession {
                                Label("Form ratings are recorded on the Apple Watch.", systemImage: "applewatch")
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("mirror-form-disabled")
                                Text("Take over logging to rate form on the phone.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else {
                                Picker("Exercise", selection: $ratingExercise) {
                                    Text("Choose").tag("")
                                    ForEach(exerciseOptions, id: \.self) { id in
                                        Text(Self.label(id)).tag(id)
                                    }
                                }
                                .onChange(of: ratingExercise) { _, id in
                                    rating = workout.formRating(for: id)?.rating ?? 4
                                }
                                if let existing = workout.formRating(for: ratingExercise) {
                                    LabeledContent("Current rating", value: "\(existing.rating) / 5")
                                        .accessibilityIdentifier("form-current-rating")
                                    Text("Saving again records a correction. The earlier rating is retained in the record; the latest is shown here.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .accessibilityIdentifier("form-correction-note")
                                }
                                Picker("Rating", selection: $rating) {
                                    ForEach(1...5, id: \.self) { value in
                                        Text("\(value)").tag(value)
                                    }
                                }
                                .pickerStyle(.segmented)
                                if let error = formError {
                                    Text(error).foregroundStyle(.red)
                                }
                                Button {
                                    Task { await saveForm(workout) }
                                } label: {
                                    HStack {
                                        Spacer()
                                        if model.isSaving {
                                            ProgressView()
                                        } else {
                                            Text(workout.formRating(for: ratingExercise) == nil ? "Save form rating" : "Save correction")
                                        }
                                        Spacer()
                                    }
                                }
                                .accessibilityIdentifier("save-form")
                                .disabled(model.isSaving || ratingExercise.isEmpty)
                            }
                        }

                        Section("Finish") {
                            if finishLocked {
                                Text("The finish response was lost. Retry the same finish; editing is locked until the server state is known.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Picker("Session RPE", selection: $rpe) {
                                Text("Not recorded").tag(Int?.none)
                                ForEach(1...10, id: \.self) { value in
                                    Text("\(value)").tag(Int?.some(value))
                                }
                            }
                            .disabled(finishLocked)
                            Picker("Productivity", selection: $productivity) {
                                Text("Not recorded").tag(Int?.none)
                                ForEach(1...5, id: \.self) { value in
                                    Text(Self.productivityLabel(value)).tag(Int?.some(value))
                                }
                            }
                            .disabled(finishLocked)
                            LabeledContent("Duration (min)") {
                                TextField("measured automatically", text: $durationText)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .accessibilityIdentifier("finish-duration")
                                    .disabled(finishLocked)
                            }
                            TextField("Notes", text: $notes, axis: .vertical)
                                .lineLimit(2...4)
                                .disabled(finishLocked)
                            if let error = finishError {
                                Text(error).foregroundStyle(.red)
                            }
                            Button {
                                Task { await finish(workout) }
                            } label: {
                                HStack {
                                    Spacer()
                                    if model.isSaving {
                                        ProgressView()
                                    } else {
                                        Text(finishLocked ? "Retry finish" : "Finish workout")
                                    }
                                    Spacer()
                                }
                            }
                            .accessibilityIdentifier("finish-workout")
                            .disabled(model.isSaving)
                        }

                        Section {
                            Button("Abandon workout", role: .destructive) {
                                confirmingAbandon = true
                            }
                            .accessibilityIdentifier("abandon-workout")
                            .disabled(finishLocked || model.isSaving)
                            if let error = abandonError {
                                Text(error).foregroundStyle(.red)
                            }
                        }
                    }
                    .onAppear { prepare(workout) }
                    .onChange(of: workout.status) { _, status in
                        if status == "completed" || status == "abandoned" {
                            dismiss()
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No active workout",
                        systemImage: "figure.strengthtraining.traditional",
                        description: Text("Start a workout from Today.")
                    )
                }
            }
            .navigationTitle("Workout")
            .navigationDestination(item: $otherExerciseId) { id in
                ExerciseWorkoutView(
                    model: model,
                    exerciseId: id,
                    planIndex: nil,
                    drafts: drafts
                )
            }
            .sheet(isPresented: $showingOtherExercisePicker) {
                ExercisePickerSheet(model: model, title: "Exercise outside plan") { id in
                    showingOtherExercisePicker = false
                    otherExerciseId = id
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { hideKeyboard() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .confirmationDialog(
                "Abandon this workout?",
                isPresented: $confirmingAbandon,
                titleVisibility: .visible
            ) {
                Button("Abandon workout", role: .destructive) {
                    Task { await abandon() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Logged sets stay in this workout, but the session will not be completed.")
            }
            .confirmationDialog(
                "Take over logging on this iPhone?",
                isPresented: $confirmingTakeOver,
                titleVisibility: .visible
            ) {
                Button("Take over logging", role: .destructive) {
                    Task { await takeOverLogging() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The watch stops logging and becomes read-only. Sets it already recorded stay in the session; anything still queued on the watch is sent when it reconnects.")
            }
            .sheet(item: $planPicker) { mode in
                ExercisePickerSheet(model: model, title: mode.title) { exerciseId in
                    planPicker = nil
                    Task {
                        switch mode {
                        case .swap(let index):
                            await swapExercise(index: index, exerciseId: exerciseId)
                        case .add:
                            await addExercise(exerciseId: exerciseId)
                        }
                    }
                }
            }
            .alert(item: $pendingRemoval) { removal in
                Alert(
                    title: Text("Remove \(removal.label)?"),
                    message: Text("Logged sets are kept. The original prescription stays unchanged."),
                    primaryButton: .destructive(Text("Remove")) {
                        Task { await removeExercise(removal) }
                    },
                    secondaryButton: .cancel()
                )
            }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    private func prepare(_ workout: WorkoutDetail) {
        if exerciseId.isEmpty, let first = exerciseOptions.first {
            exerciseId = first
        }
        if ratingExercise.isEmpty, let first = exerciseOptions.first {
            ratingExercise = first
        }
    }

    private func addSet(to workout: WorkoutDetail) async {
        addError = nil
        guard let reps = Int(repsText.trimmingCharacters(in: .whitespaces)) else {
            addError = "Reps are required."
            return
        }
        let load = parseDouble(loadText)
        if !loadText.trimmingCharacters(in: .whitespaces).isEmpty && load == nil {
            addError = "Load must be a number."
            return
        }
        let rir = parseInt(rirText)
        if !rirText.trimmingCharacters(in: .whitespaces).isEmpty && rir == nil {
            addError = "RIR must be a whole number."
            return
        }
        let velocity = parseDouble(velocityText)
        if !velocityText.trimmingCharacters(in: .whitespaces).isEmpty
            && (velocity == nil || (velocity ?? 0) <= 0) {
            addError = "Velocity must be a positive number."
            return
        }
        let repVelocities: [RepVelocity]?
        do {
            repVelocities = try RepVelocityParser.parse(repVelocityText, reps: reps)
        } catch {
            addError = error.localizedDescription
            return
        }
        let index = nextSetIndex(for: exerciseId, in: workout)
        // Unique exercises keep automatic attribution. A repeated exercise is only attributed
        // when the owner selects the exact plan item; otherwise the safe nil fallback is kept.
        let planIndex = workout.plan?.resolvedPlanItemIdentity(
            for: exerciseId,
            selected: selectedPlanItemIndex
        )
        let request = AddSetRequest(
            exerciseId: exerciseId,
            loadKg: load,
            reps: reps,
            rir: rir,
            velocityMps: velocity,
            setIndex: index,
            planItemIndex: planIndex,
            repVelocities: repVelocities
        )
        let key = addOperation.use(request)
        let localSetID = UUID().uuidString.lowercased()
        let completedAt = ExecutionEvent.nowISO()
        model.recordExecutionEvent(ExecutionEvent(
            eventType: .setStarted,
            planItemIndex: planIndex,
            localSetId: localSetID,
            payload: [
                "set_index": .number(Double(index)),
                "exercise_id": .string(exerciseId),
            ]
        ))
        if await model.addSet(request, idempotencyKey: key) {
            let savedSet = (model.activeWorkout?.sets ?? []).last {
                $0.exerciseId == exerciseId
                    && $0.setIndex == index
                    && $0.planItemIndex == planIndex
            }
            model.recordExecutionEvent(ExecutionEvent(
                eventType: .setCompleted,
                occurredAt: completedAt,
                planItemIndex: planIndex,
                setId: savedSet?.setId.flatMap { $0 > 0 ? $0 : nil },
                localSetId: localSetID,
                payload: [
                    "set_index": .number(Double(index)),
                    "exercise_id": .string(exerciseId),
                ]
            ))
            let plannedRest = workout.plan?.items.first {
                ($0.orderIndex ?? -1) == planIndex
            }?.restS ?? 120
            if rir != 6 {
                model.startRest(
                    seconds: plannedRest,
                    planItemIndex: planIndex,
                    exerciseId: exerciseId
                )
            }
            loadText = ""
            repsText = ""
            rirText = ""
            velocityText = ""
            repVelocityText = ""
            addOperation.acknowledged()
            addError = nil
        } else {
            addError = model.mutationError
        }
    }

    private func saveForm(_ workout: WorkoutDetail) async {
        formError = nil
        let request = FormRatingRequest(
            exerciseId: ratingExercise,
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

    private func removePendingSet(_ localSetId: Int) async {
        if !(await model.cancelOfflineSet(localSetId: localSetId)) {
            addError = model.mutationError
        }
    }

    private func planSetState(identity: Int, exerciseId: String) -> PlanSetState {
        var attributed = 0
        var ambiguous = 0
        for set in workout?.sets ?? [] where set.exerciseId == exerciseId {
            if let itemIdentity = set.planItemIndex {
                if itemIdentity == identity { attributed += 1 }
            } else {
                ambiguous += 1
            }
        }
        return PlanSetState(attributed: attributed, ambiguous: ambiguous)
    }

    private func canDecrease(item: PrescriptionItem, state: PlanSetState) -> Bool {
        let current = item.sets ?? 1
        return state.ambiguous == 0 && current > 1 && current - 1 >= state.attributed
    }

    private func swapExercise(index: Int, exerciseId: String) async {
        guard let workout,
              let items = workout.plan?.items,
              items.indices.contains(index),
              let expected = items[index].exerciseId else { return }
        planEditError = nil
        let key = UUID().uuidString.lowercased()
        if !(await model.swapPlanExercise(
            workoutId: workout.workoutId,
            itemIndex: index,
            exerciseId: exerciseId,
            expectedExerciseId: expected,
            idempotencyKey: key
        )) {
            planEditError = model.mutationError
        }
    }

    private func removeExercise(_ removal: PlanRemoval) async {
        guard let workout else { return }
        planEditError = nil
        let key = UUID().uuidString.lowercased()
        if !(await model.removePlanExercise(
            workoutId: workout.workoutId,
            itemIndex: removal.index,
            expectedExerciseId: removal.exerciseId,
            idempotencyKey: key
        )) {
            planEditError = model.mutationError
        }
    }

    private func changeSets(
        workout: WorkoutDetail,
        index: Int,
        delta: Int,
        exerciseId: String
    ) async {
        planEditError = nil
        let key = UUID().uuidString.lowercased()
        if !(await model.changePlanSets(
            workoutId: workout.workoutId,
            itemIndex: index,
            delta: delta,
            expectedExerciseId: exerciseId,
            idempotencyKey: key
        )) {
            planEditError = model.mutationError
        }
    }

    private func addExercise(exerciseId: String) async {
        guard let workout else { return }
        planEditError = nil
        let key = UUID().uuidString.lowercased()
        if !(await model.addPlanExercise(
            workoutId: workout.workoutId,
            exerciseId: exerciseId,
            idempotencyKey: key
        )) {
            planEditError = model.mutationError
        }
    }

    private func finish(_ workout: WorkoutDetail) async {
        finishError = nil
        let duration = parseDouble(durationText)
        if !durationText.trimmingCharacters(in: .whitespaces).isEmpty
            && (duration == nil || (duration ?? 0) <= 0) {
            finishError = "Duration must be a positive number."
            return
        }
        let request = CompleteWorkoutRequest(
            sessionRpe: rpe.map(Double.init),
            notRecorded: rpe == nil,
            durationMin: duration,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : notes,
            productivity: productivity
        )
        let key = finishLocked ? finishOperation.key : finishOperation.use(request)
        if await model.completeWorkout(request, idempotencyKey: key) {
            finishOperation.acknowledged()
            dismiss()
        } else {
            finishError = model.mutationError
            // A lost response is ambiguous: lock the body and retry the exact operation.
            // A definitive 4xx can still be corrected with a new body.
            if model.mutationFailureAmbiguous {
                finishLocked = true
            }
        }
    }

    private func abandon() async {
        guard !finishLocked else { return }
        abandonError = nil
        if await model.abandonWorkout(idempotencyKey: abandonKey) {
            dismiss()
        } else {
            abandonError = model.mutationError
        }
    }

    private func takeOverLogging() async {
        takeOverError = nil
        if !(await model.takeOverLogging()) {
            takeOverError = model.mutationError
        }
    }

    private func nextSetIndex(for exercise: String, in workout: WorkoutDetail) -> Int {
        let indexes = (workout.sets ?? [])
            .filter { $0.exerciseId == exercise }
            .compactMap(\.setIndex)
        return (indexes.max() ?? 0) + 1
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

    private static func productivityLabel(_ value: Int) -> String {
        switch value {
        case 1: return "1 — not at all"
        case 2: return "2 — slightly"
        case 3: return "3 — moderately"
        case 4: return "4 — very"
        case 5: return "5 — extremely"
        default: return "\(value)"
        }
    }

    private static func label(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func durationLabel(_ seconds: Int) -> String {
        let minutes = seconds / 60
        return "\(minutes) min"
    }
}

enum PlanPickerMode: Identifiable {
    case swap(index: Int)
    case add

    var id: String {
        switch self {
        case .swap(let index): return "swap-\(index)"
        case .add: return "add"
        }
    }

    var title: String {
        switch self {
        case .swap: return "Swap exercise"
        case .add: return "Add exercise"
        }
    }
}

struct PlanRemoval: Identifiable {
    let index: Int
    let exerciseId: String
    let label: String

    var id: String { "\(index)-\(exerciseId)" }
}

struct PlanSetState {
    let attributed: Int
    let ambiguous: Int

    var logged: Int { attributed + ambiguous }
}

private struct ExercisePickerSheet: View {
    @ObservedObject var model: AppModel
    let title: String
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [ExerciseOption] {
        guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return model.exerciseCatalogue
        }
        let query = search.localizedLowercase
        return model.exerciseCatalogue.filter { option in
            option.display.localizedLowercase.contains(query)
                || option.id.localizedLowercase.contains(query)
                || (option.pattern?.localizedLowercase.contains(query) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error = model.exerciseCatalogueError {
                    Section {
                        Text(error).foregroundStyle(.orange)
                        Button("Try again") {
                            Task { await model.loadExerciseCatalogue(force: true) }
                        }
                    }
                }
                if model.exerciseCatalogue.isEmpty, model.isLoadingExerciseCatalogue {
                    HStack {
                        Spacer()
                        ProgressView("Loading exercises…")
                        Spacer()
                    }
                } else if filtered.isEmpty {
                    ContentUnavailableView(
                        "No exercises",
                        systemImage: "magnifyingglass",
                        description: Text("Try another search.")
                    )
                } else {
                    ForEach(filtered) { option in
                        Button {
                            onSelect(option.id)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.display)
                                    .foregroundStyle(.primary)
                                if let pattern = option.pattern, !pattern.isEmpty {
                                    Text(pattern.replacingOccurrences(of: "_", with: " "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("exercise-option-\(option.id)")
                    }
                }
            }
            .searchable(text: $search, prompt: "Search exercises")
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await model.loadExerciseCatalogue() }
            .refreshable { await model.loadExerciseCatalogue(force: true) }
        }
    }
}
