import SwiftUI
import StrengthCore

/// AFC-2i: the read-only completed-workout report. Every number and label comes from the
/// server summary; this view formats and organises the payload and never recomputes a metric.
struct WorkoutReportView: View {
    @ObservedObject var model: AppModel
    let workoutId: String
    @Environment(\.dismiss) private var dismiss

    @State private var summary: WorkoutSummary?
    @State private var error: String?
    @State private var isLoading = false
    @State private var didLoad = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading report…")
                } else if let summary {
                    report(summary)
                } else {
                    unavailable
                }
            }
            .navigationTitle("Session report")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("report-done")
                }
            }
            .task {
                guard !didLoad else { return }
                didLoad = true
                await load()
            }
        }
    }

    private var unavailable: some View {
        ContentUnavailableView {
            Label("Report unavailable", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text(error ?? "The completed-workout report could not be read.")
        } actions: {
            Button("Try again") { Task { await load() } }
                .accessibilityIdentifier("report-retry")
        }
    }

    @ViewBuilder
    private func report(_ summary: WorkoutSummary) -> some View {
        List {
            Section("Session") {
                if let date = summary.forDate {
                    LabeledContent("Date", value: date)
                }
                LabeledContent("Type", value: Self.label(summary.sessionType ?? "workout"))
                if let status = summary.status {
                    LabeledContent("Status", value: Self.label(status))
                }
            }

            observationSection(summary.observation)
            adherenceSection(summary.adherence)
            vbtSection(summary.vbt)
            feedbackSection(summary.feedback)
            qualitySection(summary.quality, evidence: summary.evidence)
        }
        .accessibilityIdentifier("session-report")
    }

    @ViewBuilder
    private func observationSection(_ observation: WorkoutObservation?) -> some View {
        if let observation {
            Section("What stood out") {
                Text(observation.text)
                Text(
                    Self.label(observation.family ?? "observation")
                    + (observation.gate.map { " · \($0)" } ?? "")
                    + (observation.n.map { " · n=\($0)" } ?? "")
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                if let limitations = observation.limitations, !limitations.isEmpty {
                    DisclosureGroup("Evidence and limitations") {
                        ForEach(limitations, id: \.self) { limitation in
                            Text(limitation)
                                .font(.footnote)
                        }
                        if let evidenceId = observation.evidenceId {
                            Text(evidenceId)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .accessibilityIdentifier("report-observation")
        }
    }

    @ViewBuilder
    private func adherenceSection(_ adherence: WorkoutAdherence?) -> some View {
        Section("Prescription adherence") {
            if let adherence {
                if adherence.status != "available" || adherence.finalPlan == nil {
                    Text(Self.reason(adherence.reason, fallback: "Prescription adherence is unavailable for this session."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    if let final = adherence.finalPlan {
                        adherenceCard(
                            final,
                            title: adherence.quality?.planModified == true
                                ? "Final prescription" : "Prescription issued"
                        )
                    }
                    if adherence.quality?.planModified == true, let original = adherence.original {
                        adherenceCard(original, title: "Original prescription")
                    }
                    changes(adherence.changes)
                    adherenceQuality(adherence)
                }
            } else {
                Text("Prescription adherence is unavailable for this session.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func adherenceCard(_ view: AdherenceView, title: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.headline)
            if let matched = view.matchedSets, let prescribed = view.prescribedSets {
                Text("\(matched) of \(prescribed) prescribed sets filled")
                    .font(.subheadline)
            } else {
                Text("Set counts unavailable")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let completion = view.setCompletion {
                Text("Set completion: \(Self.ratio(completion))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Missing sets", value: Self.count(view.missingSets))
            LabeledContent("Extra sets", value: Self.count(view.extraSets))
            if let unattributable = view.unattributablePlannedSets, unattributable > 0 {
                LabeledContent(
                    "Unattributable planned sets",
                    value: "\(unattributable)"
                )
                Text("Some prescribed slots could not be attributed reliably to performed sets.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            attainment("Repetitions", view.reps)
            attainment("Load", view.load)
            attainment("RIR", view.rir)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func attainment(_ label: String, _ value: AdherenceAttainment?) -> some View {
        if let value {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(label): \(Self.ratio(value.attainment))")
                    .font(.caption)
                Text(
                    "within \(Self.count(value.withinTarget))"
                    + " · below \(Self.count(value.belowTarget))"
                    + " · above \(Self.count(value.aboveTarget))"
                    + " · unavailable \(Self.count(value.unavailableSets))"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        } else {
            Text("\(label): unavailable")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func changes(_ changes: AdherenceChanges?) -> some View {
        if let changes {
            let lines = Self.changeLines(changes)
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Changes during the workout")
                        .font(.caption)
                        .fontWeight(.semibold)
                    ForEach(lines, id: \.self) { line in
                        Text(line)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func adherenceQuality(_ adherence: WorkoutAdherence) -> some View {
        if let quality = adherence.quality {
            VStack(alignment: .leading, spacing: 2) {
                Text("Adherence quality")
                    .font(.caption)
                    .fontWeight(.semibold)
                if let unmatched = quality.unmatchedSets?.finalPlan, unmatched > 0 {
                    Text("Unmatched working sets: \(unmatched)")
                        .font(.caption2)
                }
                if let ambiguous = quality.ambiguousAttribution?.finalPlan, ambiguous > 0 {
                    Text("Ambiguous attribution: \(ambiguous)")
                        .font(.caption2)
                }
                if let sets = quality.setsWithoutRir, sets > 0 {
                    Text("Sets without RIR: \(sets)")
                        .font(.caption2)
                }
                ForEach(quality.unavailableMetrics ?? [], id: \.self) { code in
                    Text("Unavailable: \(Self.reason(code, fallback: code))")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private func vbtSection(_ vbt: WorkoutVBT?) -> some View {
        Section("Velocity") {
            if let vbt {
                if vbt.status != "available" {
                    Text(Self.reason(vbt.reason, fallback: "Velocity data is unavailable for this session."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    if let quality = vbt.quality {
                        LabeledContent("Target sets", value: Self.count(quality.targetSets))
                        LabeledContent("Comparable sets", value: Self.count(quality.comparableSets))
                        LabeledContent("Excluded sets", value: Self.count(quality.excludedSets))
                        if let metadata = quality.targetMetadata, !metadata.isEmpty {
                            Text("Target metadata: " + metadata.keys.sorted().map {
                                "\($0) \(metadata[$0] ?? 0)"
                            }.joined(separator: " · "))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(vbt.exercises ?? []) { exercise in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.label(exercise.exerciseId))
                                .font(.caption)
                                .fontWeight(.semibold)
                            Text(
                                "comparable \(Self.count(exercise.comparableSets))"
                                + " · excluded \(Self.count(exercise.excludedSets))"
                                + " · mean Δ \(Self.signed(exercise.meanSignedDeltaMps, unit: "m/s"))"
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            if let band = exercise.withinCalibrationBand {
                                Text("Within band: \(Self.ratio(band))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                Text("Velocity data is unavailable for this session.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func feedbackSection(_ feedback: WorkoutFeedback?) -> some View {
        Section("Session feedback") {
            if let feedback {
                LabeledContent("sRPE", value: feedback.srpe.map { Self.number($0) } ?? "Not recorded")
                LabeledContent("Duration", value: feedback.durationMin.map {
                    "\(Self.number($0)) min" + (feedback.durationSource.map { " · \($0)" } ?? "")
                } ?? "Unavailable")
                LabeledContent("Session load", value: feedback.sessionLoadAu.map {
                    "\(Self.number($0)) AU" + (Self.loadStatus(feedback.sessionLoadStatus).map { " · \($0)" } ?? "")
                } ?? "Unavailable")
                LabeledContent("Productivity", value: feedback.productivity.map(String.init) ?? "Not recorded")
            } else {
                Text("Session feedback is unavailable.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func qualitySection(_ quality: WorkoutSummaryQuality?, evidence: [WorkoutEvidence]?) -> some View {
        Section("Data quality") {
            let flags = quality?.flags ?? []
            if flags.isEmpty {
                Text("No known data-quality limitations.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(flags) { flag in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(flag.code)
                            .font(.caption)
                        if let detail = flag.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("report-quality-flags")
            }
            if let evidence, !evidence.isEmpty {
                DisclosureGroup("Evidence") {
                    ForEach(evidence) { item in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.source)
                                .font(.caption)
                            Text("\(item.gate ?? "unknown") · \(item.comparability ?? "unknown")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            ForEach(item.limitations ?? [], id: \.self) { limitation in
                                Text(limitation)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("report-evidence")
            }
        }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            summary = try await model.workoutSummary(workoutId: workoutId)
        } catch {
            summary = nil
            self.error = error.localizedDescription
        }
    }

    // MARK: - Formatting (no metric arithmetic)

    nonisolated private static func ratio(_ value: AdherenceRatio?) -> String {
        guard let value else { return "Unavailable" }
        let counts = "\(count(value.numerator)) / \(count(value.denominator))"
        guard let ratio = value.ratio else { return counts }
        return counts + " (ratio " + String(format: "%.2f", ratio) + ")"
    }

    nonisolated private static func count(_ value: Int?) -> String {
        value.map(String.init) ?? "Unavailable"
    }

    nonisolated private static func signed(_ value: Double?, unit: String) -> String {
        guard let value else { return "Unavailable" }
        let sign = value > 0 ? "+" : ""
        return sign + String(format: "%.2f", value) + " " + unit
    }

    nonisolated private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    nonisolated private static func loadStatus(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if case .string(let text) = value { return text }
        return nil
    }

    nonisolated private static func label(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    nonisolated private static func reason(_ code: String?, fallback: String) -> String {
        guard let code, !code.isEmpty else { return fallback }
        let known: [String: String] = [
            "no_prescription_snapshot": "No frozen prescription snapshot exists for this session.",
            "session_voided": "This session is voided and excluded from adherence analysis.",
            "no_prescription_items": "No prescription items were recorded for this workout.",
            "workout_not_found": "The linked workout record is missing.",
            "workout_not_completed": "The linked workout was not completed.",
            "vbt_unavailable": "No VBT data is available for this workout.",
            "no_vbt_target_issued": "No VBT target was issued for this workout.",
            "missing_prescribed_load": "No comparable prescribed load was recorded.",
            "missing_actual_load": "No actual load was recorded.",
            "missing_prescribed_reps": "No repetition target was recorded.",
            "missing_actual_reps": "No actual repetitions were recorded.",
            "missing_prescribed_rir": "No RIR target was recorded.",
            "missing_actual_rir": "No actual RIR was recorded.",
        ]
        return known[code] ?? code.replacingOccurrences(of: "_", with: " ")
    }

    nonisolated private static func changeLines(_ changes: AdherenceChanges) -> [String] {
        var lines: [String] = []
        for change in changes.swapped ?? [] {
            lines.append("Swapped \(label(change.fromExerciseId ?? "exercise")) → \(label(change.toExerciseId ?? "exercise"))")
        }
        for change in changes.added ?? [] {
            lines.append("Added \(label(change.exerciseId ?? "exercise"))" + (change.sets.map { " (\($0) sets)" } ?? ""))
        }
        for change in changes.removed ?? [] {
            lines.append("Removed \(label(change.exerciseId ?? "exercise"))")
        }
        for change in changes.setCountChanged ?? [] {
            lines.append(
                "Set count changed: \(label(change.exerciseId ?? "exercise")) → "
                + (change.sets.map { "\($0) sets" } ?? "unavailable")
            )
        }
        for change in changes.targetsChanged ?? [] {
            lines.append("Targets changed: \(label(change.exerciseId ?? "exercise"))")
        }
        return lines
    }
}
