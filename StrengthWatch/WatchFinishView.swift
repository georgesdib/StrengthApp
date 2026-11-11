import StrengthCore
import SwiftUI

/// The end flow: summary, session RPE on the Digital Crown, Finish, and a confirmed discard.
struct WatchFinishView: View {
    @ObservedObject var execution: WatchExecutionController
    @Environment(\.dismiss) private var dismiss

    @State private var sessionRpe = 7.0
    @State private var notRecorded = false
    @State private var confirmingDiscard = false
    @State private var isSaving = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Session RPE").font(.headline)
                Text(notRecorded ? "—" : "\(Int(sessionRpe))")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .focusable()
                    .digitalCrownRotation(
                        $sessionRpe,
                        from: 1,
                        through: 10,
                        by: 1,
                        sensitivity: .medium
                    )
                    .disabled(notRecorded)
                Text("\(execution.completedSetCount) sets · \(execution.pendingCount) pending")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Toggle("Not recorded", isOn: $notRecorded)
                Button("Finish") {
                    isSaving = true
                    Task {
                        await execution.finish(sessionRpe: notRecorded ? nil : sessionRpe)
                        isSaving = false
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
                .accessibilityIdentifier("watch-finish")
                Button("Discard session") { confirmingDiscard = true }
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .confirmationDialog(
            "Discard this session?",
            isPresented: $confirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard session", role: .destructive) {
                Task {
                    await execution.discard()
                    dismiss()
                }
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The workout is abandoned and nothing is recorded.")
        }
    }
}
