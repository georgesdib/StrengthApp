import SwiftUI

struct PrescriptionPreviewView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var startKey = UUID().uuidString.lowercased()
    @State private var localError: String?

    private var issued: IssuedPlanResponse? {
        if case .issued(let issued) = model.prescriptionState {
            return issued
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if let workout = model.activeWorkout, workout.status == "in_progress" {
                    ActiveWorkoutView(model: model)
                } else if let issued {
                    Form {
                        Section("Session") {
                            LabeledContent("Type", value: issued.plan.sessionLabel
                                           ?? Self.label(issued.sessionType))
                            LabeledContent("Date", value: issued.forDate)
                            LabeledContent("Expires", value: issued.expiresAt)
                            if let readiness = issued.readiness {
                                LabeledContent("Readiness", value: Self.readinessLabel(readiness))
                                if let basis = readiness.basis, !basis.isEmpty {
                                    Text(basis)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Section("Plan") {
                            ForEach(issued.plan.items) { item in
                                VStack(alignment: .leading, spacing: 4) {
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
                                    if let refs = item.refs, !refs.isEmpty {
                                        Text(refs.joined(separator: ", "))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }

                        let warnings = issued.warnings + (issued.plan.warnings ?? [])
                        if !warnings.isEmpty {
                            Section("Warnings") {
                                ForEach(Array(Set(warnings)).sorted(), id: \.self) { warning in
                                    Label(warning, systemImage: "exclamationmark.triangle")
                                        .font(.footnote)
                                }
                            }
                        }

                        if let error = localError ?? model.mutationError {
                            Section {
                                Text(error).foregroundStyle(.red)
                            }
                        }

                        Section {
                            Button {
                                Task {
                                    if !(await model.startWorkout(idempotencyKey: startKey)) {
                                        localError = model.mutationError
                                    }
                                }
                            } label: {
                                HStack {
                                    Spacer()
                                    if model.isSaving {
                                        ProgressView()
                                    } else {
                                        Text("Start workout")
                                    }
                                    Spacer()
                                }
                            }
                            .accessibilityIdentifier("preview-start")
                            .disabled(model.isSaving)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No prescription",
                        systemImage: "list.bullet.clipboard",
                        description: Text("Issue a prescription from Today first.")
                    )
                }
            }
            .navigationTitle(model.activeWorkout == nil ? "Review prescription" : "Workout")
            .toolbar {
                if model.activeWorkout == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            model.clearPrescription()
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private static func label(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func readinessLabel(_ score: ReadinessScore) -> String {
        let value = score.score.map { "\(Int(($0 * 100).rounded()))%" } ?? "no score"
        return "\(score.status.capitalized) · \(value)"
    }
}
