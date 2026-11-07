import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if let error = model.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Button("Try again") {
                            Task { await model.loadHistory(reset: true) }
                        }
                    }
                }

                if model.sessions.isEmpty {
                    if model.isLoadingHistory {
                        HStack {
                            Spacer()
                            ProgressView("Loading history…")
                            Spacer()
                        }
                    } else if model.errorMessage == nil {
                        ContentUnavailableView(
                            "No sessions yet",
                            systemImage: "clock",
                            description: Text(
                                "Completed sessions will appear here once the server has them."
                            )
                        )
                    }
                } else {
                    ForEach(model.sessions) { session in
                        HistoryRow(session: session)
                    }
                    if model.hasMoreHistory {
                        Button {
                            Task { await model.loadMoreHistory() }
                        } label: {
                            HStack {
                                Spacer()
                                if model.isLoadingHistory {
                                    ProgressView()
                                } else {
                                    Text("Load more")
                                }
                                Spacer()
                            }
                        }
                        .disabled(model.isLoadingHistory)
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.loadHistory(reset: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.isLoadingHistory)
                    .accessibilityLabel("Refresh history")
                }
            }
            .refreshable { await model.loadHistory(reset: true) }
            .task {
                if !model.hasLoadedHistory {
                    await model.loadHistory(reset: true)
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let session: HistorySession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.occurredOn)
                    .font(.headline)
                Spacer()
                Text(Self.sessionLabel(session.sessionType))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if let sets = session.setCount {
                    Text("\(sets) set\(sets == 1 ? "" : "s")")
                }
                if let tonnage = session.tonnageKg, tonnage > 0 {
                    Text("\(Int(tonnage.rounded()).formatted()) kg")
                }
                if let marks = session.marks, marks > 0 {
                    Text("\(marks) mark\(marks == 1 ? "" : "s")")
                }
                if session.needsReview == 1 {
                    Text("needs review")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let lifts = session.mainLifts, !lifts.isEmpty {
                Text(lifts.map(Self.liftLabel).joined(separator: ", "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    nonisolated private static func sessionLabel(_ type: String?) -> String {
        guard let type, !type.isEmpty, type != "unknown" else { return "Session" }
        return type.capitalized
    }

    nonisolated private static func liftLabel(_ exerciseId: String) -> String {
        exerciseId
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}
