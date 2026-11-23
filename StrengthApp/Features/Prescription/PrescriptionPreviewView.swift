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

            if issued.techniqueThrottleInForce {
                Section("Technique throttle") {
                    Label("MOD-TECH-001 is in force for this session", systemImage: "gauge.with.dots.needle.33percent")
                        .font(.subheadline)
                    Text("Main-work loads are lower than a full session because you asked for a technique throttle. The server applied it when this plan was built; accessory work is unchanged. Every affected exercise is marked below.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("technique-throttle-in-force")
            }

            if let topSet = issued.plan.topSet, topSet.reasonCode != "intent_off" {
                Section("Top set") {
                    LabeledContent("Outcome", value: topSet.statusLabel)
                    if let reason = topSet.reason, !reason.isEmpty {
                        Text(reason)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if topSet.isApplied,
                       let load = topSet.topSetLoadKg,
                       let rir = topSet.topSetRir {
                        LabeledContent(
                            "Heaviest set",
                            value: String(format: "%.1f kg · RIR %d", load, rir)
                        )
                    }
                }
                .accessibilityIdentifier("top-set-status")
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
                            if (item.refs ?? []).contains("MOD-TECH-001") {
                                Text("throttled")
                                    .foregroundStyle(.orange)
                            }
                            if let velocity = item.velocityTargetLabel {
                                Text("target \(velocity)")
                            }
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
                    .disabled(
                        model.isSaving
                            || model.hasPendingOfflineCapture
                            || (model.isOffline && issued.executionID == nil)
                    )
                    if model.hasPendingOfflineCapture {
                        Text("Resolve the pending capture before starting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if model.isOffline && issued.executionID != nil {
                        Text("Offline. The start is saved and binds the plan's execution id when the server is reachable.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if model.isOffline {
                        Text("Starting requires the server for this plan.")
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

    nonisolated static func readinessLabel(_ readiness: ReadinessScore) -> String {
        if let score = readiness.score {
            return "\(Int((score * 100).rounded()))% · " + readiness.status.capitalized
        }
        return readiness.status.capitalized
    }
}
