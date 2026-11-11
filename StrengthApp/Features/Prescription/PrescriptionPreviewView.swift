import SwiftUI
import StrengthCore

/// Read-only review of the issued plan. Start lives here, not on Today, so the owner always sees
/// the exercises before consuming the plan.
struct PrescriptionPreviewView: View {
    @ObservedObject var model: AppModel
    var onStarted: () -> Void

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
                if let issued {
                    review(issued)
                } else {
                    ContentUnavailableView(
                        "No prescription",
                        systemImage: "list.bullet.clipboard",
                        description: Text("Issue a prescription from Today first.")
                    )
                }
            }
            .navigationTitle("Review workout")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func review(_ issued: IssuedPlanResponse) -> some View {
        Form {
            Section("Session") {
                LabeledContent("Type", value: issued.plan.sessionLabel ?? Self.label(issued.sessionType))
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
                            Text("rest \(item.restS ?? 120)s")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if let warmups = item.warmup, !warmups.isEmpty {
                            Text("Warm-ups: " + warmups.map { "\(Self.load($0.loadKg))×\($0.reps)" }.joined(separator: ", "))
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
                if issued.executionTarget == "watch" {
                    Text("Requested for Apple Watch. Start this workout on the watch.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("watch-targeted-plan")
                } else {
                    Button {
                        start()
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
                    .disabled(model.isSaving || model.isOffline || model.hasPendingOfflineCapture)
                    if model.isOffline || model.hasPendingOfflineCapture {
                        Text("Starting requires the server.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func start() {
        guard case .issued = model.prescriptionState else { return }
        localError = nil
        Task {
            if await model.startWorkout(idempotencyKey: startKey) {
                onStarted()
                dismiss()
            } else {
                localError = model.mutationError
            }
        }
    }

    nonisolated private static func label(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    nonisolated private static func load(_ value: Double) -> String {
        value == value.rounded()
            ? "\(Int(value))kg"
            : String(format: "%.1fkg", value)
    }

    nonisolated private static func readinessLabel(_ readiness: ReadinessScore) -> String {
        if let score = readiness.score {
            return String(format: "%.1f", score) + " / 100 · " + readiness.status.capitalized
        }
        return readiness.status.capitalized
    }
}
