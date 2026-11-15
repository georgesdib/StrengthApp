import SwiftUI

/// Deterministic weekly review: sections, coverage and limitations, with no model and no
/// client-side arithmetic. Every value is rendered from the envelope the server produced.
public struct WeeklyReviewView: View {
    @StateObject private var model: WeeklyReviewViewModel

    public init(model: WeeklyReviewViewModel) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        List {
            if let error = model.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Button("Try again") { Task { await model.load() } }
                }
            }

            if let envelope = model.envelope {
                header(envelope)
                activity(envelope)
                adherence(envelope)
                sessions(envelope)
                progression(envelope)
                volume(envelope)
                readiness(envelope)
                programme(envelope)
                observations(envelope)
                footer(envelope)
            } else if model.isLoading {
                Section { ProgressView("Loading the review…") }
            }
        }
        .navigationTitle("Weekly review")
        .refreshable { await model.load() }
        .task {
            if model.envelope == nil { await model.load() }
        }
    }

    @ViewBuilder
    private func header(_ envelope: IntelligenceEnvelope) -> some View {
        Section {
            LabeledContent("Week", value: "\(envelope.period.start) to \(envelope.period.end)")
            LabeledContent("Status", value: envelope.status.replacingOccurrences(of: "_", with: " "))
            if let flags = envelope.qualityFlags, !flags.isEmpty {
                LabeledContent("Quality", value: flags.joined(separator: ", "))
            }
            HStack {
                Button("Previous week") { Task { await model.step(byWeeks: -1) } }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Next week") { Task { await model.step(byWeeks: 1) } }
                    .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func activity(_ envelope: IntelligenceEnvelope) -> some View {
        if let fact = envelope.facts["activity"], let value = fact.value.objectValue {
            Section("Activity") {
                LabeledContent("Completed", value: value["completed_sessions"]?.displayText ?? "—")
                LabeledContent("Target", value: value["target_sessions"]?.displayText ?? "—")
                LabeledContent("Working sets", value: value["working_sets"]?.displayText ?? "—")
                LabeledContent("With sRPE", value: value["sessions_with_srpe"]?.displayText ?? "—")
                if let types = value["session_types"]?.objectValue, !types.isEmpty {
                    ForEach(types.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: types[key]?.displayText ?? "—")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func adherence(_ envelope: IntelligenceEnvelope) -> some View {
        if let fact = envelope.facts["adherence"], let value = fact.value.objectValue {
            Section("Adherence") {
                if value["available"]?.boolValue == true {
                    LabeledContent("Planned sets", value: value["planned_sets"]?.displayText ?? "—")
                    LabeledContent("Matched sets", value: value["matched_sets"]?.displayText ?? "—")
                    LabeledContent("Missing sets", value: value["missing_sets"]?.displayText ?? "—")
                    LabeledContent("Extra sets", value: value["extra_sets"]?.displayText ?? "—")
                    if let ratio = value["final_plan_ratio"]?.doubleValue {
                        LabeledContent("Final-plan completion", value: String(format: "%.2f", ratio))
                    }
                } else {
                    Text("No comparable app-tracked workout this week.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func sessions(_ envelope: IntelligenceEnvelope) -> some View {
        if let fact = envelope.facts["sessions"], let rows = fact.value.arrayValue, !rows.isEmpty {
            Section("Sessions") {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    if let value = row.objectValue {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(value["date"]?.displayText ?? "—")
                            Text("\(value["session_type"]?.displayText ?? "—") · \(value["working_sets"]?.displayText ?? "—") working sets")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func progression(_ envelope: IntelligenceEnvelope) -> some View {
        if let fact = envelope.facts["progression"], let rows = fact.value.arrayValue, !rows.isEmpty {
            Section("Progression") {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    if let value = row.objectValue {
                        LabeledContent(value["display"]?.displayText ?? "—",
                                       value: direction(value["direction"]?.displayText ?? "—"))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func volume(_ envelope: IntelligenceEnvelope) -> some View {
        if let fact = envelope.facts["volume"], let value = fact.value.objectValue {
            Section("Volume") {
                LabeledContent("Status", value: (value["status"]?.displayText ?? "—").replacingOccurrences(of: "_", with: " "))
                if let groups = value["groups"]?.arrayValue, !groups.isEmpty {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, row in
                        if let group = row.objectValue {
                            LabeledContent(group["pattern"]?.displayText ?? "—",
                                           value: "\(group["average"]?.displayText ?? "—") sets/week")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func readiness(_ envelope: IntelligenceEnvelope) -> some View {
        if let fact = envelope.facts["readiness"], let value = fact.value.objectValue {
            Section("Readiness") {
                LabeledContent("Days observed", value: value["observed_days"]?.displayText ?? "—")
                LabeledContent("Direction", value: direction(value["direction"]?.displayText ?? "—"))
                Text("Values are never returned; this section is coverage and direction only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func programme(_ envelope: IntelligenceEnvelope) -> some View {
        if let fact = envelope.facts["programme"], let value = fact.value.objectValue {
            Section("Programme") {
                LabeledContent("Deload", value: (value["deload"]?.displayText ?? "—").replacingOccurrences(of: "_", with: " "))
                LabeledContent("Regime", value: (value["regime_review"]?.displayText ?? "—").replacingOccurrences(of: "_", with: " "))
                LabeledContent("Findings", value: value["regime_findings"]?.displayText ?? "—")
            }
        }
    }

    @ViewBuilder
    private func observations(_ envelope: IntelligenceEnvelope) -> some View {
        if let rows = envelope.observations, !rows.isEmpty {
            Section("Observations") {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.text)
                        Text("\(row.family) · gate \(row.gate ?? "insufficient")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func footer(_ envelope: IntelligenceEnvelope) -> some View {
        Section("Coverage") {
            ForEach(envelope.coverage.keys.sorted(), id: \.self) { key in
                LabeledContent(key.replacingOccurrences(of: "_", with: " "),
                               value: envelope.coverage[key]?.displayText ?? "—")
            }
        }
        if !envelope.missing.isEmpty {
            Section("Missing") {
                ForEach(envelope.missing, id: \.self) { Text($0).font(.callout) }
            }
        }
        if !envelope.limitations.isEmpty {
            Section("Limitations") {
                ForEach(envelope.limitations, id: \.self) { Text($0).font(.callout) }
            }
        }
    }

    private func direction(_ raw: String) -> String {
        switch raw {
        case "up": return "Up"
        case "down": return "Down"
        case "flat": return "Flat"
        default: return "Unknown"
        }
    }
}
