import SwiftUI
import UIKit

struct ActiveWorkoutView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var exerciseId = ""
    @State private var selectedPlanItemIndex: Int?
    @State private var loadText = ""
    @State private var repsText = ""
    @State private var rirText = ""
    @State private var velocityText = ""
    @State private var addOperation = OperationKey<AddSetRequest>()
    @State private var addError: String?

    @State private var ratingExercise = ""
    @State private var rating = 4
    @State private var formOperation = OperationKey<FormRatingRequest>()
    @State private var formError: String?

    @State private var rpe = 7
    @State private var notRecorded = false
    @State private var durationText = ""
    @State private var notes = ""
    @State private var finishOperation = OperationKey<CompleteWorkoutRequest>()
    @State private var finishLocked = false
    @State private var finishError: String?

    @State private var abandonKey = UUID().uuidString.lowercased()
    @State private var confirmingAbandon = false
    @State private var abandonError: String?

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
                        Section("Workout") {
                            LabeledContent("Session", value: Self.label(workout.sessionType ?? "workout"))
                            LabeledContent("Date", value: workout.forDate ?? "—")
                            LabeledContent("Status", value: Self.label(workout.status))
                            if let elapsed = workout.elapsedSeconds {
                                LabeledContent("Elapsed", value: Self.durationLabel(elapsed))
                            }
                        }

                        Section("Plan") {
                            ForEach(workout.plan?.items ?? []) { item in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(Self.label(item.exerciseId ?? "exercise"))
                                            .font(.headline)
                                        Spacer()
                                        if let sets = item.sets {
                                            Text("\(sets) sets")
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    HStack(spacing: 8) {
                                        Text(item.repsLabel)
                                        Text(item.loadLabel)
                                        Text(item.effortLabel)
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
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
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
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

                        Section("Add set") {
                            Picker("Exercise", selection: $exerciseId) {
                                Text("Choose").tag("")
                                ForEach(exerciseOptions, id: \.self) { id in
                                    Text(Self.label(id)).tag(id)
                                }
                            }
                            .onChange(of: exerciseId) { _, _ in
                                selectedPlanItemIndex = nil
                            }
                            if planChoices.count > 1 {
                                Picker("Prescription item", selection: $selectedPlanItemIndex) {
                                    Text("Not attributed").tag(Int?.none)
                                    ForEach(planChoices) { choice in
                                        Text(choice.label).tag(Optional(choice.index))
                                    }
                                }
                                .accessibilityIdentifier("set-plan-item")
                                Text("This exercise appears more than once. Choose the exact prescription item, or leave it unattributed.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            LabeledContent("Load (kg)") {
                                TextField("optional", text: $loadText)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .accessibilityIdentifier("set-load")
                            }
                            LabeledContent("Reps") {
                                TextField("required", text: $repsText)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .accessibilityIdentifier("set-reps")
                            }
                            LabeledContent("RIR") {
                                TextField("0-6", text: $rirText)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .accessibilityIdentifier("set-rir")
                            }
                            LabeledContent("Mean velocity (m/s)") {
                                TextField("optional", text: $velocityText)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .accessibilityIdentifier("set-velocity")
                            }
                            if let error = addError {
                                Text(error).foregroundStyle(.red)
                            }
                            Button {
                                Task { await addSet(to: workout) }
                            } label: {
                                HStack {
                                    Spacer()
                                    if model.isSaving { ProgressView() } else { Text("Save set") }
                                    Spacer()
                                }
                            }
                            .accessibilityIdentifier("save-set")
                            .disabled(model.isSaving || exerciseId.isEmpty)
                        }

                        Section("Form rating") {
                            Picker("Exercise", selection: $ratingExercise) {
                                Text("Choose").tag("")
                                ForEach(exerciseOptions, id: \.self) { id in
                                    Text(Self.label(id)).tag(id)
                                }
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
                                    if model.isSaving { ProgressView() } else { Text("Save form rating") }
                                    Spacer()
                                }
                            }
                            .accessibilityIdentifier("save-form")
                            .disabled(model.isSaving || ratingExercise.isEmpty)
                        }

                        Section("Finish") {
                            if finishLocked {
                                Text("The finish response was lost. Retry the same finish; editing is locked until the server state is known.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Toggle("Session RPE not recorded", isOn: $notRecorded)
                                .disabled(finishLocked)
                            if !notRecorded {
                                Picker("Session RPE", selection: $rpe) {
                                    ForEach(1...10, id: \.self) { value in
                                        Text("\(value)").tag(value)
                                    }
                                }
                                .disabled(finishLocked)
                            }
                            LabeledContent("Duration (min)") {
                                TextField("optional", text: $durationText)
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
        if durationText.isEmpty, let elapsed = workout.elapsedSeconds, elapsed > 0 {
            durationText = String(format: "%.1f", Double(elapsed) / 60.0)
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
        let index = nextSetIndex(for: exerciseId, in: workout)
        // Unique exercises keep automatic attribution. A repeated exercise is only attributed
        // when the owner selects the exact plan item; otherwise the safe nil fallback is kept.
        let planIndex = workout.plan?.resolvedPlanItemIndex(
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
            planItemIndex: planIndex
        )
        let key = addOperation.use(request)
        if await model.addSet(request, idempotencyKey: key) {
            loadText = ""
            repsText = ""
            rirText = ""
            velocityText = ""
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

    private func finish(_ workout: WorkoutDetail) async {
        finishError = nil
        let duration = parseDouble(durationText)
        if !durationText.trimmingCharacters(in: .whitespaces).isEmpty
            && (duration == nil || (duration ?? 0) <= 0) {
            finishError = "Duration must be a positive number."
            return
        }
        let request = CompleteWorkoutRequest(
            sessionRpe: notRecorded ? nil : Double(rpe),
            notRecorded: notRecorded,
            durationMin: duration,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : notes
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

    private static func label(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func durationLabel(_ seconds: Int) -> String {
        let minutes = seconds / 60
        return "\(minutes) min"
    }
}
