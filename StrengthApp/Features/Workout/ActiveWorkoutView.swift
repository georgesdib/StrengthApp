import SwiftUI
import UIKit
import StrengthCore

private struct WorkoutReportTarget: Identifiable {
    let id: String
}

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
    @State private var substituteTarget: ExecutionTarget?
    @State private var additionTarget: ExecutionTarget?
    @State private var executionError: String?
    @StateObject private var drafts = WorkoutDraftStore()
    @State private var otherExerciseId: String?
    @State private var showingOtherExercisePicker = false
    @State private var reportTarget: WorkoutReportTarget?
    @State private var finishAcknowledged = false

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

                        if let rejection = model.executionChangeRejection,
                           rejection.workoutID == workout.workoutId {
                            Section("Plan change not applied") {
                                Text(rejection.message)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                                Text("The session keeps the sets already recorded. Refresh to load the current plan.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                Button("Dismiss") {
                                    model.dismissExecutionChangeRejection()
                                }
                            }
                            .accessibilityIdentifier("execution-change-rejection")
                        }

                        if !model.pendingExecutionChanges.isEmpty {
                            Section("Pending plan change") {
                                Text("Queued on this phone. It is not on the server yet.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                ForEach(model.pendingExecutionChanges) { entry in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.kind.label)
                                            .font(.subheadline)
                                        Text("Queued \(entry.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        HStack {
                                            Button("Retry now") {
                                                Task { await model.retryPendingMutations() }
                                            }
                                            .disabled(model.isRecovering || model.isSaving)
                                            Button("Discard", role: .destructive) {
                                                model.discardPendingMutation(entry)
                                            }
                                            .disabled(model.isRecovering || model.isSaving)
                                        }
                                        .font(.caption)
                                    }
                                }
                            }
                            .accessibilityIdentifier("pending-plan-change")
                        }

                        if !model.conflictedExecutionChanges.isEmpty {
                            Section("Plan change needs attention") {
                                Text(
                                    "This change could not be confirmed and cannot be retried. The session kept the sets already recorded; discard the entry if the plan on screen is correct."
                                )
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                ForEach(model.conflictedExecutionChanges) { entry in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.kind.label)
                                            .font(.subheadline)
                                        Text("Conflict · \(entry.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Button("Discard", role: .destructive) {
                                            model.discardPendingMutation(entry)
                                        }
                                        .disabled(model.isRecovering || model.isSaving)
                                        .font(.caption)
                                    }
                                }
                            }
                            .accessibilityIdentifier("conflicted-plan-change")
                        }

                        Section {
                            let planItems = workout.plan?.items ?? []
                            ForEach(Array(planItems.enumerated()), id: \.offset) { index, item in
                                let exercise = item.exerciseId ?? ""
                                let identity = item.orderIndex ?? index
                                let row = model.executionRow(forPlanIndex: identity)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(Self.label(row?.exerciseId ?? (exercise.isEmpty ? "exercise" : exercise)))
                                            .font(.headline)
                                        Spacer()
                                        if let sets = row?.sets ?? item.sets {
                                            Text(String(sets) + " sets")
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                        }
                                        Menu {
                                            Button("Substitute exercise…") {
                                                substituteTarget = ExecutionTarget(id: identity)
                                            }
                                            .disabled(
                                                model.isSaving || exercise.isEmpty
                                                    || (workout.sets ?? []).contains {
                                                        $0.planItemIndex == identity
                                                    }
                                            )
                                            Button("Add extra work after…") {
                                                additionTarget = ExecutionTarget(id: identity)
                                            }
                                            .disabled(model.isSaving || exercise.isEmpty)
                                        } label: {
                                            Image(systemName: "ellipsis.circle")
                                                .accessibilityLabel("Exercise options")
                                        }
                                        .disabled(model.isSaving)
                                    }
                                    if let groups = row?.groups, !groups.isEmpty {
                                        // One row per planned group, in order; the item-level
                                        // summary is not shown so a top set and its back-off
                                        // stay distinct.
                                        VStack(alignment: .leading, spacing: 1) {
                                            ForEach(Array(groups.enumerated()), id: \.offset) {
                                                groupIndex, group in
                                                Text(group.rowLabel)
                                                    .accessibilityIdentifier(
                                                        "plan-group-\(index)-\(groupIndex)"
                                                    )
                                            }
                                            if let velocity = row?.velocityTargetLabel
                                                ?? item.velocityTargetLabel {
                                                Text("target " + velocity)
                                            }
                                            if let note = row?.topSetNote {
                                                Text(note)
                                                    .foregroundStyle(.secondary)
                                            }
                                            if model.isExerciseActive(
                                                planItemIndex: identity,
                                                exerciseId: row?.exerciseId ?? exercise
                                            ) {
                                                Label("In progress", systemImage: "timer")
                                                    .foregroundStyle(.orange)
                                            }
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    } else {
                                        HStack(spacing: 8) {
                                            Text(row?.repsLabel ?? item.repsLabel)
                                            Text(row?.loadLabel ?? item.loadLabel)
                                            Text(row?.effortLabel ?? item.effortLabel)
                                            if let velocity = row?.velocityTargetLabel
                                                ?? item.velocityTargetLabel {
                                                Text("target " + velocity)
                                            }
                                            if let note = row?.topSetNote {
                                                Text(note)
                                                    .foregroundStyle(.secondary)
                                            }
                                            if model.isExerciseActive(
                                                planItemIndex: identity,
                                                exerciseId: row?.exerciseId ?? exercise
                                            ) {
                                                Label("In progress", systemImage: "timer")
                                                    .foregroundStyle(.orange)
                                            }
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                    if let row, row.kind == .substituted {
                                        Text(
                                            "Changed on this phone"
                                                + (row.plannedExerciseId.map { " from " + Self.label($0) } ?? "")
                                        )
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                        .accessibilityIdentifier("substituted-" + String(index))
                                    }
                                    if let note = row?.localStateNote {
                                        Text(note)
                                            .font(.caption2)
                                            .foregroundStyle(
                                                row?.change?.localState == "rejected" ? .red : .orange
                                            )
                                            .accessibilityIdentifier("execution-local-state-" + String(index))
                                    }
                                    NavigationLink {
                                        ExerciseWorkoutView(
                                            model: model,
                                            exerciseId: row?.exerciseId ?? exercise,
                                            planIndex: index,
                                            row: row,
                                            substitutesPlanItemIndex: row?.substitutesPlanItemIndex,
                                            drafts: drafts
                                        )
                                    } label: {
                                        Label("Open sets", systemImage: "list.bullet")
                                            .font(.caption)
                                    }
                                    .accessibilityIdentifier("open-exercise-" + String(index))
                                }
                                .padding(.vertical, 2)
                            }
                            if let error = executionError {
                                Text(error)
                                    .foregroundStyle(.red)
                                    .accessibilityIdentifier("execution-change-error")
                            }
                        } header: {
                            Text("Plan")
                        }

                        if !model.unlinkedWatchSets.isEmpty {
                            Section("Sets outside the plan") {
                                Text("These sets are saved but are not attached to a plan item. This normally means the Apple Watch recorded them before a plan change reached it.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                ForEach(model.unlinkedWatchSets) { set in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(Self.label(set.exerciseId))
                                            .font(.subheadline)
                                        Text("Set \(set.setIndex ?? 0) · \(set.summary)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .accessibilityIdentifier("unlinked-watch-sets")
                        }

                        let additions = model.executionRows.filter { $0.kind == .added }
                        if !additions.isEmpty {
                            Section("Extra work") {
                                ForEach(additions) { row in
                                    NavigationLink {
                                        ExerciseWorkoutView(
                                            model: model,
                                            exerciseId: row.exerciseId,
                                            planIndex: nil,
                                            row: row,
                                            drafts: drafts
                                        )
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(Self.label(row.exerciseId))
                                            Text(row.repsLabel + " · " + row.loadLabel)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }

                        Section("Outside the plan") {
                            Button {
                                showingOtherExercisePicker = true
                            } label: {
                                Label("Log an exercise not in the plan", systemImage: "plus.circle")
                            }
                            .disabled(model.isSaving)
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
                    .onAppear {
                        prepare(workout)
                        // Opening a recovered server workout resolves the prompt that led here.
                        model.clearRecoveryIssue()
                        // Re-read the execution view so a change authored on the phone (or on
                        // another session) is visible here (DEC-RESOLVER-23).
                        Task { await model.refreshExecutionView(workoutId: workout.workoutId) }
                    }
                    .onChange(of: workout.status) { _, status in
                        if (status == "completed" || status == "abandoned"),
                           !finishAcknowledged {
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
            .sheet(item: $substituteTarget) { target in
                ExercisePickerSheet(model: model, title: "Substitute exercise") { id in
                    substituteTarget = nil
                    Task { await substitute(planItemIndex: target.id, exerciseId: id) }
                }
            }
            .sheet(item: $additionTarget) { target in
                ExercisePickerSheet(model: model, title: "Add extra work after") { id in
                    additionTarget = nil
                    Task { await addExtraWork(afterItemIndex: target.id, exerciseId: id) }
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
            .fullScreenCover(item: $reportTarget, onDismiss: {
                dismiss()
            }) { target in
                WorkoutReportView(model: model, workoutId: target.id)
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

    private func removePendingSet(_ localSetId: Int) async {
        if !(await model.cancelOfflineSet(localSetId: localSetId)) {
            addError = model.mutationError
        }
    }

    private func substitute(planItemIndex: Int, exerciseId: String) async {
        guard let workout else { return }
        executionError = nil
        let key = UUID().uuidString.lowercased()
        if !(await model.recordExecutionChange(
            workoutId: workout.workoutId,
            planItemIndex: planItemIndex,
            exerciseId: exerciseId,
            idempotencyKey: key
        )) {
            executionError = model.mutationError
        }
    }

    private func addExtraWork(afterItemIndex: Int, exerciseId: String) async {
        guard let workout else { return }
        executionError = nil
        let key = UUID().uuidString.lowercased()
        if !(await model.recordExecutionChange(
            workoutId: workout.workoutId,
            afterItemIndex: afterItemIndex,
            exerciseId: exerciseId,
            repsLow: 8,
            repsHigh: 12,
            rirTarget: 2,
            idempotencyKey: key
        )) {
            executionError = model.mutationError
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
        // The status callback must not dismiss the workout while the report is being presented.
        finishAcknowledged = true
        if await model.completeWorkout(request, idempotencyKey: key) {
            finishOperation.acknowledged()
            if model.offlineFinishPending {
                // No authoritative summary exists until the queued finish syncs. The report
                // remains reachable from History after that acknowledgement.
                dismiss()
            } else {
                reportTarget = WorkoutReportTarget(id: workout.workoutId)
            }
        } else {
            finishAcknowledged = false
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

struct ExecutionTarget: Identifiable {
    let id: Int
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
