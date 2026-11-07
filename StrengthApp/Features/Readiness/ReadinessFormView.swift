import SwiftUI
import UIKit

struct ReadinessFormView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private struct Field: Identifiable {
        let id: String
        let label: String
        let hint: String
    }

    private let coreFields = [
        Field(id: "sleep", label: "Sleep", hint: "1-5"),
        Field(id: "energy", label: "Energy", hint: "1-5"),
        Field(id: "mood", label: "Mood", hint: "1-5"),
        Field(id: "soreness", label: "Soreness", hint: "1-5"),
        Field(id: "stress", label: "Stress", hint: "1-5 (5 = no stress)"),
    ]
    private let measureFields = [
        Field(id: "hrv_ms", label: "HRV", hint: "ms, optional"),
        Field(id: "rhr_bpm", label: "Resting HR", hint: "bpm, optional"),
        Field(id: "bodyweight_kg", label: "Bodyweight", hint: "kg, optional"),
        Field(id: "wearable_score", label: "Wearable score", hint: "0-100, optional"),
    ]
    private let legacyFields = [
        Field(id: "squat_readiness", label: "Squat readiness", hint: "legacy 1-5"),
        Field(id: "bench_readiness", label: "Bench readiness", hint: "legacy 1-5"),
        Field(id: "deadlift_readiness", label: "Deadlift readiness", hint: "legacy 1-5"),
    ]

    @State private var text: [String: String] = [:]
    @State private var note = ""
    @State private var localError: String?
    @State private var operation = OperationKey<ReadinessWriteRequest>()

    var body: some View {
        Form {
                Section {
                    ForEach(coreFields) { field in
                        fieldRow(field)
                    }
                } header: {
                    Text("Core readiness")
                } footer: {
                    Text("Leave anything you did not record empty. The server keeps missing values missing.")
                }

                Section("Measurements") {
                    ForEach(measureFields) { field in
                        fieldRow(field)
                    }
                }

                Section("Legacy labels") {
                    ForEach(legacyFields) { field in
                        fieldRow(field)
                    }
                }

                Section("Note") {
                    TextField("Optional note", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }

                if let error = localError ?? model.mutationError {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        HStack {
                            Spacer()
                            if model.isSaving {
                                ProgressView()
                            } else {
                                Text("Save readiness")
                            }
                            Spacer()
                        }
                    }
                    .accessibilityIdentifier("save-readiness")
                    .disabled(model.isSaving)
                }
            }
            .navigationTitle("Log readiness")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { hideKeyboard() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
    }

    private func fieldRow(_ field: Field) -> some View {
        LabeledContent(field.label) {
            TextField(field.hint, text: binding(field.id))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(field.label)
                .accessibilityIdentifier("readiness-\(field.id)")
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(
            get: { text[key] ?? "" },
            set: { text[key] = $0 }
        )
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    private func save() async {
        localError = nil
        var values: [String: Double] = [:]
        for field in coreFields + measureFields + legacyFields {
            let raw = (text[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty { continue }
            guard let value = Double(raw.replacingOccurrences(of: ",", with: ".")) else {
                localError = "\(field.label) must be a number."
                return
            }
            values[field.id] = value
        }
        guard !values.isEmpty else {
            localError = "Enter at least one readiness field."
            return
        }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = ReadinessWriteRequest(
            values: values,
            note: trimmedNote.isEmpty ? nil : trimmedNote
        )
        let key = operation.use(request)
        if await model.saveReadiness(
            values: values,
            note: request.note,
            idempotencyKey: key
        ) {
            operation.acknowledged()
            dismiss()
        }
    }
}
