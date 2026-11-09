import SwiftUI
import StrengthCore

struct ExerciseDetailView: View {
    @ObservedObject var model: AppModel
    let exerciseId: String
    let display: String

    private var detail: ExerciseDetailResponse? {
        guard model.exerciseDetail?.exercise.id == exerciseId else { return nil }
        return model.exerciseDetail
    }

    var body: some View {
        List {
            if model.isLoadingExerciseDetail, detail == nil {
                HStack {
                    Spacer()
                    ProgressView("Loading exercise…")
                    Spacer()
                }
            }
            if let error = model.exerciseDetailError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Button("Try again") { Task { await reload() } }
                }
            }

            if let detail {
                overview(detail)
                e1rmSection(detail)
                historySection
                configurationSection(detail)
            }
        }
        .navigationTitle(display)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isLoadingExerciseDetail || model.isLoadingExerciseHistory)
                .accessibilityLabel("Refresh exercise")
            }
        }
        .task {
            await reload()
        }
    }

    private func reload() async {
        await model.loadExerciseDetail(exerciseId: exerciseId)
        await model.loadExerciseHistory(exerciseId: exerciseId, reset: true)
    }

    @ViewBuilder
    private func overview(_ detail: ExerciseDetailResponse) -> some View {
        Section("Overview") {
            LabeledContent("ID", value: detail.exercise.id)
            if let pattern = detail.exercise.pattern {
                LabeledContent("Pattern", value: pattern.replacingOccurrences(of: "_", with: " ").capitalized)
            }
            if let source = detail.exercise.source {
                LabeledContent("Source", value: source)
            }
            ForEach(overviewKeys, id: \.self) { key in
                if let value = propertyText(key) {
                    LabeledContent(label(key), value: value)
                }
            }
        }
    }

    private let overviewKeys = [
        "primary_muscles", "day_roles", "vbt_family", "loadable",
        "bodyweight_type", "time_based", "main_lift", "primary_compound",
        "default_rir_target", "spinal_cost", "programme_slot_of",
        "history_equivalent_of", "log_names",
    ]

    @ViewBuilder
    private func e1rmSection(_ detail: ExerciseDetailResponse) -> some View {
        Section("e1RM") {
            if !detail.e1rmApplicable {
                Text(detail.e1rmReason ?? "This exercise is not e1RM-applicable.")
                    .foregroundStyle(.secondary)
            } else if let e1rm = detail.e1rm {
                if let latest = e1rm.summary.latest {
                    LabeledContent("Latest", value: "\(format(latest.kg)) kg on \(latest.date)")
                        .accessibilityIdentifier("exercise-e1rm-latest")
                }
                if let best = e1rm.summary.best {
                    LabeledContent("Best eligible", value: "\(format(best.kg)) kg on \(best.date)")
                }
                if let median = e1rm.summary.recentMedianKg {
                    LabeledContent("Recent median", value: "\(format(median)) kg")
                }
                LabeledContent("Eligible observations", value: "\(e1rm.summary.n) · \(e1rm.summary.status)")
                Text("\(e1rm.from) to \(e1rm.to) · \(basisLabel(e1rm.basis)) · decay \(e1rm.decay), calibration \(e1rm.calibration).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if e1rm.points.isEmpty {
                    Text("No eligible e1RM observations in this range.")
                        .foregroundStyle(.secondary)
                } else {
                    DisclosureGroup("Eligible observations (\(e1rm.points.count))") {
                        ForEach(e1rm.points.suffix(15)) { point in
                            HStack {
                                Text(point.date)
                                Spacer()
                                Text("\(format(point.kg)) kg")
                                Text("median \(format(point.rollingMedianKg))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                }
                if !e1rm.degraded.isEmpty {
                    DisclosureGroup("Degraded observations excluded (\(e1rm.degraded.count))") {
                        ForEach(e1rm.degraded) { point in
                            HStack {
                                Text(point.date)
                                Spacer()
                                Text("\(format(point.kg)) kg · \(point.quality)")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                }
                if !e1rm.breaks.isEmpty {
                    DisclosureGroup("Series breaks (\(e1rm.breaks.count))") {
                        ForEach(e1rm.breaks) { item in
                            Text("\(item.date): \(item.reason)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("No e1RM data available.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var historySection: some View {
        Section {
            historyContent
        } header: {
            Text("History")
                .accessibilityIdentifier("exercise-history-header")
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        Group {
            if let error = model.exerciseHistoryError {
                Text(error).foregroundStyle(.red)
                Button("Try again") {
                    Task {
                        await model.loadExerciseHistory(
                            exerciseId: exerciseId, reset: true
                        )
                    }
                }
            }
            if model.exerciseHistorySessions.isEmpty {
                if model.isLoadingExerciseHistory {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if model.exerciseHistoryError == nil {
                    Text("No completed working-set history for this exercise.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(model.exerciseHistorySessions) { session in
                    NavigationLink {
                        HistoryDetailView(model: model, sessionID: session.sessionId)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(session.occurredOn)
                                Spacer()
                                Text(session.sessionType?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Session")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(session.sets.prefix(12)) { set in
                                Text(set.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if session.sets.count > 12 {
                                Text("+ \(session.sets.count - 12) more sets")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                if !model.exerciseHistoryIncluded.isEmpty,
                   model.exerciseHistoryIncluded.contains(where: { $0.id != exerciseId }) {
                    Text("Includes history equivalents: "
                         + model.exerciseHistoryIncluded
                        .filter { $0.id != exerciseId }
                        .map(\.display)
                        .joined(separator: ", "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if model.exerciseHistoryHasMore {
                    Button {
                        Task {
                            await model.loadExerciseHistory(
                                exerciseId: exerciseId, reset: false
                            )
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if model.isLoadingExerciseHistory { ProgressView() }
                            else { Text("Load older sessions") }
                            Spacer()
                        }
                    }
                    .disabled(model.isLoadingExerciseHistory)
                }
                Text("Showing \(model.exerciseHistorySessions.count) of \(model.exerciseHistoryTotal) sessions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func configurationSection(_ detail: ExerciseDetailResponse) -> some View {
        Section("Configuration") {
            DisclosureGroup("All configuration") {
                ForEach(detail.properties.keys.sorted(), id: \.self) { key in
                    if let value = propertyText(key) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key)
                                .font(.caption.monospaced())
                            Text(value)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func propertyText(_ key: String) -> String? {
        guard let detail, let value = detail.properties[key] else { return nil }
        return render(value)
    }

    private func render(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text):
            return text.isEmpty ? nil : text
        case .number(let number):
            return number.rounded() == number ? String(Int(number)) : String(number)
        case .bool(let bool):
            return bool ? "yes" : "no"
        case .array(let values):
            let text = values.compactMap(render).joined(separator: ", ")
            return text.isEmpty ? nil : text
        case .object(let object):
            let text = object.keys.sorted().compactMap { key in
                guard let value = render(object[key]!) else { return nil }
                return "\(key): \(value)"
            }.joined(separator: ", ")
            return text.isEmpty ? nil : text
        case .null:
            return nil
        }
    }

    private func label(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func basisLabel(_ value: String) -> String {
        value == "raw_formula_epley_rir" ? "raw formula Epley/RIR" : value
    }

    private func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
