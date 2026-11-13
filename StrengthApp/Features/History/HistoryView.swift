import SwiftUI
import StrengthCore

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
    @State private var execution: ExecutionAnalyticsResponse?
    @State private var executionUnavailable = false
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
                executionSection
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

    @ViewBuilder
    private var executionSection: some View {
        if let execution {
            Section("Execution") {
                if execution.events.isEmpty {
                    Text("No execution events were recorded for this workout. Set and rest timing is unavailable.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Active lifting", value: Self.secondsLabel(execution.summary.activeLiftingS))
                    LabeledContent("Recorded rest", value: Self.secondsLabel(execution.summary.recordedRecoveryS))
                    LabeledContent("Exercise transitions", value: Self.secondsLabel(execution.summary.exerciseTransitionS))
                    LabeledContent("Total elapsed", value: Self.secondsLabel(execution.totalElapsedS))
                    LabeledContent("Events", value: "\(execution.dataQuality.eventCount)")
                    if let started = execution.dataQuality.setStartedEvents,
                       let completed = execution.dataQuality.setCompletedEvents,
                       started > completed {
                        Text("\(started - completed) set start(s) have no completion timestamp; their duration is unavailable.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if let started = execution.dataQuality.restStartedEvents,
                       let ended = execution.dataQuality.restEndedEvents,
                       started > ended {
                        Text("\(started - ended) rest start(s) have no end timestamp; their duration is unavailable.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            if !execution.sets.isEmpty {
                Section("Set timing") {
                    ForEach(execution.sets) { set in
                        LabeledContent(
                            set.localSetId.map { "Set \($0.prefix(8))" } ?? "Set \(set.setId ?? 0)",
                            value: Self.secondsLabel(set.durationS)
                        )
                    }
                }
            }
            if !execution.rests.isEmpty {
                Section("Rest comparison") {
                    ForEach(execution.rests) { rest in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(rest.outcome == "completed" ? "Completed rest" : "Rest ended early")
                                .font(.subheadline)
                            Text("Prescribed \(rest.prescribedRestS.map(Self.secondsLabel) ?? "not recorded") · actual \(Self.secondsLabel(rest.actualRestS))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let deviation = rest.deviationS {
                                Text("Deviation \(Self.signedSeconds(deviation))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !execution.events.isEmpty {
                Section("Timeline") {
                    ForEach(execution.events) { event in
                        HStack(alignment: .top, spacing: 10) {
                            Text(Self.timeLabel(event.occurredAt))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 62, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.eventLabel(event.eventType))
                                    .font(.subheadline)
                                if let setId = event.setId {
                                    Text("Set ID \(setId)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        } else if executionUnavailable {
            Section("Execution") {
                Text("Execution timeline is unavailable for this workout. Historical workouts without execution events are not backfilled.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
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
            do {
                execution = try await model.executionAnalytics(workoutId: sessionID)
            } catch {
                execution = nil
                executionUnavailable = true
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    nonisolated private static func eventLabel(_ type: String) -> String {
        type.replacingOccurrences(of: "_", with: " ").capitalized
    }

    nonisolated private static func timeLabel(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso)
            ?? ISO8601DateFormatter().date(from: iso)
        guard let date else { return iso }
        return date.formatted(date: .omitted, time: .shortened)
    }

    nonisolated private static func secondsLabel(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    nonisolated private static func signedSeconds(_ seconds: Double) -> String {
        String(format: "%+.0f s", seconds)
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
