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
                        NavigationLink {
                            HistoryDetailView(model: model, sessionID: session.sessionId)
                        } label: {
                            HistoryRow(session: session)
                        }
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
                if let duration = session.durationMin, duration > 0 {
                    Text("\(Int(duration.rounded())) min")
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

struct HistoryDetailView: View {
    @ObservedObject var model: AppModel
    let sessionID: String
    @State private var detail: HistoryDetail?
    @State private var error: String?
    @State private var isLoading = false

    var body: some View {
        List {
            if let error {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                    Button("Try again") { Task { await load() } }
                }
            }
            if let detail {
                Section("Session") {
                    LabeledContent("Date", value: detail.occurredOn)
                    LabeledContent("Type", value: Self.sessionLabel(detail.sessionType ?? detail.workoutLabel))
                    LabeledContent("Duration", value: Self.durationLabel(detail))
                    LabeledContent("Sets", value: "\(detail.setCount ?? 0)")
                    if let tonnage = detail.tonnageKg, tonnage > 0 {
                        LabeledContent("Tonnage", value: "\(Int(tonnage.rounded()).formatted()) kg")
                    }
                    if let lifts = detail.mainLifts, !lifts.isEmpty {
                        LabeledContent("Main lifts", value: lifts.map(Self.liftLabel).joined(separator: ", "))
                    }
                }
                Section("Outline") {
                    if groupedSets.isEmpty {
                        Text("No set detail recorded.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(groupedSets.enumerated()), id: \.offset) { _, exercise in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(Self.liftLabel(exercise.0))
                                    .font(.headline)
                                ForEach(exercise.1) { set in
                                    Text(set.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            } else if isLoading {
                HStack {
                    Spacer()
                    ProgressView("Loading workout…")
                    Spacer()
                }
            }
        }
        .navigationTitle("Workout")
        .task { await load() }
    }

    private var groupedSets: [(String, [HistoryDetailSet])] {
        var order: [String] = []
        var groups: [String: [HistoryDetailSet]] = [:]
        for set in detail?.sets ?? [] {
            if groups[set.exerciseId] == nil { order.append(set.exerciseId) }
            groups[set.exerciseId, default: []].append(set)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            detail = try await model.historyDetail(sessionID: sessionID)
        } catch {
            self.error = error.localizedDescription
        }
    }

    nonisolated private static func sessionLabel(_ type: String?) -> String {
        guard let type, !type.isEmpty, type != "unknown" else { return "Session" }
        return type.capitalized
    }

    nonisolated private static func liftLabel(_ exerciseId: String) -> String {
        exerciseId.replacingOccurrences(of: "_", with: " ").capitalized
    }

    nonisolated private static func durationLabel(_ detail: HistoryDetail) -> String {
        guard let duration = detail.durationMin, duration > 0 else { return "Not recorded" }
        let value = "\(Int(duration.rounded())) min"
        guard let basis = detail.durationBasis, !basis.isEmpty else { return value }
        return "\(value) (\(basis))"
    }
}
