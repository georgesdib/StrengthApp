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
            LabeledContent("Week", value: model.weekLabel)
            Text("\(envelope.period.start) to \(envelope.period.end)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Label(envelope.status.replacingOccurrences(of: "_", with: " "),
                      systemImage: statusIcon(envelope.status))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(statusTint(envelope.status))
                Spacer()
                if let flags = envelope.qualityFlags, !flags.isEmpty {
                    ReviewBadge(text: flags.joined(separator: " · "),
                                systemImage: "exclamationmark.circle", tint: .orange)
                }
            }
            if envelope.status == "no_data" {
                Text("No completed session in this week. This is missing data, not a negative result.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if envelope.coverage["week_partial"]?.intValue == 1 {
                Text("This week is still in progress; sections cover completed work so far.")
                    .font(.callout)
                    .foregroundStyle(.orange)
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
                Text("Target-based exposure; no planned-session calendar exists.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    Text("Matched against prescribed sets in the final frozen plan, which may have "
                         + "been modified after issue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let ratio = value["final_plan_ratio"]?.doubleValue {
                        LabeledContent("Final-plan completion",
                                       value: ratio.formatted(.percent.precision(.fractionLength(0))))
                    }
                    LabeledContent("Planned sets", value: value["planned_sets"]?.displayText ?? "—")
                    LabeledContent("Matched sets", value: value["matched_sets"]?.displayText ?? "—")
                    LabeledContent("Missing sets", value: value["missing_sets"]?.displayText ?? "—")
                    LabeledContent("Extra sets", value: value["extra_sets"]?.displayText ?? "—")
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
                Text("Change is the latest e1RM versus the recent median, not a tested maximum.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    if let value = row.objectValue {
                        let direction = value["direction"]?.displayText ?? "unknown"
                        HStack(spacing: 10) {
                            ReviewBadge(text: directionLabel(direction),
                                        systemImage: directionIcon(direction),
                                        tint: directionTint(direction))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(value["display"]?.displayText ?? "—")
                                if let n = value["n"]?.displayText {
                                    Text("\(n) observations")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                if let change = value["change_kg"]?.doubleValue {
                                    Text(change, format: .number.precision(.fractionLength(1)))
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundStyle(directionTint(direction))
                                        .accessibilityLabel("versus recent median \(change) kilograms")
                                }
                                if let median = value["recent_median_kg"]?.doubleValue {
                                    Text("median \(median.formatted(.number.precision(.fractionLength(1)))) kg")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func volume(_ envelope: IntelligenceEnvelope) -> some View {
        if let fact = envelope.facts["volume"], let value = fact.value.objectValue {
            let status = value["status"]?.displayText ?? "unknown"
            Section("Volume") {
                HStack {
                    ReviewBadge(text: status.replacingOccurrences(of: "_", with: " "),
                                systemImage: "chart.bar.fill", tint: volumeTint(status))
                    Spacer()
                    if let window = value["window_weeks"]?.intValue {
                        Text("\(window)-week rolling window")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let coverage = value["coverage"]?.objectValue,
                   let observed = coverage["observed_weeks"]?.intValue,
                   let denominator = coverage["denominator"]?.intValue {
                    Text("Weeks with data: \(observed) of \(denominator)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let groups = value["groups"]?.arrayValue, !groups.isEmpty {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, row in
                        if let group = row.objectValue {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(group["pattern"]?.displayText ?? "—")
                                    Spacer()
                                    if let average = group["average"]?.doubleValue {
                                        Text(average, format: .number.precision(.fractionLength(1)))
                                            .font(.subheadline.monospacedDigit())
                                    }
                                }
                                HStack(spacing: 8) {
                                    if let target = group["target"]?.arrayValue {
                                        Text(target.map { $0.displayText }.joined(separator: "–") + " target")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    ReviewBadge(text: group["status"]?.displayText ?? "—",
                                                systemImage: "circle.fill",
                                                tint: volumeTint(group["status"]?.displayText ?? ""))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func readiness(_ envelope: IntelligenceEnvelope) -> some View {
        if let fact = envelope.facts["readiness"], let value = fact.value.objectValue {
            let direction = value["direction"]?.displayText ?? "unknown"
            Section("Readiness") {
                LabeledContent("Days observed", value: value["observed_days"]?.displayText ?? "—")
                HStack {
                    Text("Direction")
                    Spacer()
                    ReviewBadge(text: directionLabel(direction),
                                systemImage: directionIcon(direction),
                                tint: directionTint(direction))
                }
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
                LabeledContent(
                    "Deload policy",
                    value: (value["deload_policy"]?.displayText ?? "—")
                        .replacingOccurrences(of: "_", with: " ")
                )
                if let reason = value["deload_reason"]?.stringValue {
                    Text("Reason: \(reason)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Policy state on the Sunday; it does not mean a deload was performed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Regime", value: (value["regime_review"]?.displayText ?? "—").replacingOccurrences(of: "_", with: " "))
                if let findings = value["regime_findings_detail"]?.arrayValue, !findings.isEmpty {
                    ForEach(Array(findings.enumerated()), id: \.offset) { _, row in
                        if let finding = row.objectValue {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(finding["main_lift"]?.displayText ?? "—")
                                Text(regimeLine(finding))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text("No regime findings this week.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func observations(_ envelope: IntelligenceEnvelope) -> some View {
        if let rows = envelope.observations, !rows.isEmpty {
            Section("Observations") {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.text)
                        HStack(spacing: 8) {
                            ReviewBadge(text: row.family,
                                        systemImage: "text.magnifyingglass", tint: .blue)
                            if let n = row.n {
                                Text("n=\(n)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            ReviewBadge(text: "gate \(row.gate ?? "insufficient")",
                                        systemImage: "checkmark.seal",
                                        tint: row.gate == "signal" ? .teal : .secondary)
                        }
                        if let limitations = row.limitations, !limitations.isEmpty {
                            ForEach(limitations, id: \.self) { limitation in
                                Label(limitation, systemImage: "info.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
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

    private func directionLabel(_ raw: String) -> String {
        switch raw {
        case "up": return "Up"
        case "down": return "Down"
        case "flat": return "Flat"
        default: return "Unknown"
        }
    }

    private func directionIcon(_ raw: String) -> String {
        switch raw {
        case "up": return "arrow.up.right"
        case "down": return "arrow.down.right"
        case "flat": return "arrow.right"
        default: return "questionmark"
        }
    }

    private func directionTint(_ raw: String) -> Color {
        switch raw {
        case "up": return .green
        case "down": return .orange
        case "flat": return .secondary
        default: return .secondary
        }
    }

    private func volumeTint(_ status: String) -> Color {
        switch status {
        case "within_budget", "within", "optimal": return .green
        case "above_budget", "over": return .orange
        case "mixed", "under": return .yellow
        default: return .secondary
        }
    }

    private func regimeLine(_ finding: [String: JSONValue]) -> String {
        var parts: [String] = []
        if let kind = finding["kind"]?.displayText {
            parts.append(kind)
        }
        if let drop = finding["drop_pct"]?.doubleValue {
            parts.append("-\(drop.formatted(.number.precision(.fractionLength(1))))%")
        }
        if let substitutes = finding["substitutes"]?.arrayValue, let first = substitutes.first?.objectValue,
           let lift = first["exercise_id"]?.displayText,
           let increase = first["increase"]?.displayText {
            parts.append("substitute \(lift) +\(increase)")
        }
        return parts.joined(separator: " · ")
    }

    private func statusIcon(_ status: String) -> String {
        status == "ok" ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private func statusTint(_ status: String) -> Color {
        status == "ok" ? .green : .orange
    }
}

private struct ReviewBadge: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}
