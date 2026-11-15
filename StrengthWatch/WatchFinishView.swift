import StrengthCore
import SwiftUI

/// The end flow: summary, session RPE on the Digital Crown, Finish, and a confirmed discard.
struct WatchFinishView: View {
    @ObservedObject var execution: WatchExecutionController
    @Environment(\.dismiss) private var dismiss

    @State private var sessionRpe = 7.0
    @State private var notRecorded = false
    @State private var productivity: Int?
    @State private var confirmingDiscard = false
    @State private var isSaving = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Session RPE").font(.headline)
                HStack(spacing: 8) {
                    Button {
                        sessionRpe = max(1, sessionRpe - 1)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .disabled(notRecorded || sessionRpe <= 1)
                    .accessibilityIdentifier("watch-session-rpe-minus")

                    Text(notRecorded ? "—" : "\(Int(sessionRpe))")
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        .frame(minWidth: 54)
                        .focusable()
                        .digitalCrownRotation(
                            $sessionRpe,
                            from: 1,
                            through: 10,
                            by: 1,
                            sensitivity: .medium,
                            isContinuous: false,
                            isHapticFeedbackEnabled: true
                        )
                        .disabled(notRecorded)
                        .accessibilityIdentifier("watch-session-rpe")
                        .accessibilityValue(notRecorded ? "Not recorded" : "\(Int(sessionRpe))")

                    Button {
                        sessionRpe = min(10, sessionRpe + 1)
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .disabled(notRecorded || sessionRpe >= 10)
                    .accessibilityIdentifier("watch-session-rpe-plus")
                }
                Text("\(execution.completedSetCount) sets · \(execution.pendingCount) pending")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Toggle("Not recorded", isOn: $notRecorded)
                Text("Productivity").font(.headline)
                VStack(spacing: 4) {
                    ForEach(1...5, id: \.self) { value in
                        Button {
                            productivity = value
                        } label: {
                            HStack {
                                Text("\(value)")
                                Spacer()
                                if productivity == value {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(productivity == value ? .accentColor : .gray)
                        .accessibilityIdentifier("watch-productivity-\(value)")
                    }
                }
                Button("Not recorded") { productivity = nil }
                    .font(.caption2)
                    .foregroundStyle(productivity == nil ? .primary : .secondary)
                Button("Finish") {
                    isSaving = true
                    Task {
                        await execution.finish(
                            sessionRpe: notRecorded ? nil : sessionRpe,
                            productivity: productivity
                        )
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
