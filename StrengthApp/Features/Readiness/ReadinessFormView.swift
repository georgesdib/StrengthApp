import SwiftUI
import UIKit
import StrengthCore

/// Schema-driven readiness entry. The server's effective registry supplies the enabled fields,
/// order, labels, scales, units and direction; bodyweight and the wearable score stay separate
/// non-registry inputs. The client only validates for convenience and submits the values map.
struct ReadinessFormView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// Every field the fixed fallback form can write. Kept as a stable test/introspection surface;
    /// the live form renders model.readinessSchema instead.
    static var inputFieldIds: [String] {
        ReadinessSchema.fallback.enabledMetrics.map(\.key)
            + ["bodyweight_kg", "wearable_score"]
    }

    private var schema: ReadinessSchema { model.readinessSchema }

    @State private var text: [String: String] = [:]
    @State private var note = ""
    @State private var localError: String?
    @State private var fieldErrors: [String: String] = [:]
    @State private var operation = OperationKey<ReadinessWriteRequest>()

    var body: some View {
        Form {
            if schema.registryId != nil
                || model.readinessSchemaSource != .server
                || model.readinessSchemaError != nil {
                schemaSection
            }

            Section {
                ForEach(schema.enabledCoreMetrics, id: \.key) { metric in
                    metricRow(metric)
                }
            } header: {
                Text("Core readiness")
            } footer: {
                Text(coreFooter)
            }

            if model.bootstrap?.capabilities.healthkitReadiness == true {
                healthKitSection
            }

            if !schema.enabledDeviceMetrics.isEmpty {
                Section {
                    ForEach(schema.enabledDeviceMetrics, id: \.key) { metric in
                        metricRow(metric)
                    }
                } header: {
                    Text("Device measurements")
                } footer: {
                    Text("Optional measured inputs. Enter the value in the unit shown.")
                }
            }

            Section {
                extraRow(
                    "Bodyweight",
                    key: "bodyweight_kg",
                    placeholder: "kg, optional"
                )
                extraRow(
                    "Wearable score",
                    key: "wearable_score",
                    placeholder: "0–100, optional"
                )
            } header: {
                Text("Other inputs")
            } footer: {
                Text("Bodyweight and the wearable score are stored with readiness but are not registry metrics.")
            }

            Section("Note") {
                TextField("Optional note", text: $note, axis: .vertical)
                    .lineLimit(2...4)
                if let error = fieldErrors["note"] {
                    errorText(error, id: "readiness-error-note")
                }
            }

            if let error = localError ?? model.mutationError {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Spacer()
                        if model.isSaving {
                            ProgressView()
                        } else {
                            Text("Save readiness")
                        }
                        Spacer()
                    }
                }
                .accessibilityIdentifier("save-readiness")
                .disabled(model.isSaving)
            }
        }
        .navigationTitle("Log readiness")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { hideKeyboard() }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .task { await model.loadReadinessSchema() }
    }

    // MARK: - Schema status

    @ViewBuilder
    private var schemaSection: some View {
        Section {
            if model.readinessSchemaSource != .server || model.readinessSchemaError != nil {
                Text(schemaNotice)
                    .font(.footnote)
                if let error = model.readinessSchemaError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let registryId = schema.registryId {
                Text("Readiness registry v\(registryId)\(schema.effectiveFrom.map { " (effective \($0))" } ?? "").")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Readiness form")
        }
    }

    private var schemaNotice: String {
        let suffix = " Metrics added to the server registry since this form was last saved are not "
            + "available offline, and no value is invented for them; they appear after the next sync."
        switch model.readinessSchemaSource {
        case .server:
            return "Server unreachable: showing the readiness form last loaded from this server."
                + suffix
        case .cache:
            let version = schema.registryId.map { " (registry v\($0))" } ?? ""
            return "Server unreachable: showing the readiness form last saved for this server"
                + version + "." + suffix
        case .fallback:
            return "Server unreachable: showing the standard readiness fields." + suffix
        }
    }

    private var coreFooter: String {
        var parts: [String] = []
        let required = schema.requiredMetricLabels
        if !required.isEmpty {
            parts.append("Required: at least one of \(list(required)).")
        }
        parts.append("Enter at least \(schema.minCoreFields) core fields for a score.")
        return parts.joined(separator: " ")
    }

    // MARK: - HealthKit

    @ViewBuilder
    private var healthKitSection: some View {
        Section {
            if !model.healthKitEnabled {
                Text("HealthKit is off. Enter the measurement manually, or enable it in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                healthKitRow(
                    metricLabel("hrv_ms", fallback: "HRV"),
                    field: "hrv_ms",
                    unit: metricUnit("hrv_ms", fallback: "ms")
                )
                healthKitRow(
                    metricLabel("rhr_bpm", fallback: "Resting HR"),
                    field: "rhr_bpm",
                    unit: metricUnit("rhr_bpm", fallback: "bpm")
                )
                healthKitRow("Bodyweight", field: "bodyweight_kg", unit: "kg")
                Button {
                    Task { await model.importHealthKit() }
                } label: {
                    HStack {
                        Spacer()
                        if model.isImportingHealthKit {
                            ProgressView()
                        } else {
                            Text("Refresh HealthKit")
                        }
                        Spacer()
                    }
                }
                .disabled(model.isImportingHealthKit)
                if let error = model.healthKitRefreshError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("From HealthKit")
        } footer: {
            Text("Automatic values are shown here. Enter a value below to override it; manual readiness wins.")
        }
    }

    @ViewBuilder
    private func healthKitRow(_ label: String, field: String, unit: String) -> some View {
        let payload = model.today?.readiness
        let value = metricValue(field)
        let provenance = payload?.healthkit?[field]
        let source = payload?.sources?[field]
        let status = HealthKitReadinessField(rawValue: field).flatMap {
            model.healthKitSelection?.status(for: $0)
        }
        if let value {
            LabeledContent(label, value: "\(value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)")
            if source == "manual", let provenance {
                Text("Manual selected; HealthKit \(provenance.value.formatted(.number.precision(.fractionLength(0...1)))) \(unit) from \(provenance.sourceName) \(sampleAge(provenance.sampleAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let provenance {
                Text("\(provenance.sourceName) \(sampleAge(provenance.sampleAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let source {
                Text(source == "manual" ? "Manual" : source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if status == .stale {
            Text("\(label): stale HealthKit sample")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            Text(
                field == "hrv_ms"
                    ? "\(label): no recovery reading"
                    : "\(label): no sample"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func metricValue(_ field: String) -> Double? {
        switch field {
        case "hrv_ms": return model.today?.readiness?.hrvMs
        case "rhr_bpm": return model.today?.readiness?.rhrBpm
        case "bodyweight_kg": return model.today?.readiness?.bodyweightKg
        default: return nil
        }
    }

    private func metricLabel(_ key: String, fallback: String) -> String {
        schema.metric(key)?.label ?? fallback
    }

    private func metricUnit(_ key: String, fallback: String) -> String {
        schema.metric(key)?.unit ?? fallback
    }

    private func sampleAge(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: iso)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: iso)
        }
        guard let date else { return "sample time unknown" }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .short
        return relative.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Rows

    private func metricRow(_ metric: ReadinessMetric) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                TextField(metric.inputPlaceholder, text: binding(metric.key))
                    .keyboardType(metric.isCore ? .numberPad : .decimalPad)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(Text(accessibilityLabel(metric)))
                    .accessibilityIdentifier("readiness-\(metric.key)")
            } label: {
                HStack(spacing: 2) {
                    Text(metric.label)
                    if schema.isRequiredOneOf(metric) {
                        Text("*")
                            .foregroundStyle(.red)
                    }
                }
            }
            Text(metric.inputHint)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = fieldErrors[metric.key] {
                errorText(error, id: "readiness-error-\(metric.key)")
            }
        }
    }

    private func extraRow(_ title: String, key: String, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                TextField(placeholder, text: binding(key))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(title)
                    .accessibilityIdentifier("readiness-\(key)")
            }
            if let error = fieldErrors[key] {
                errorText(error, id: "readiness-error-\(key)")
            }
        }
    }

    private func errorText(_ message: String, id: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .accessibilityIdentifier(id)
    }

    private func accessibilityLabel(_ metric: ReadinessMetric) -> String {
        schema.isRequiredOneOf(metric)
            ? "\(metric.label), required one of"
            : metric.label
    }

    private func list(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        if items.count == 1 { return last }
        if items.count == 2 { return "\(items[0]) or \(last)" }
        return items.dropLast().joined(separator: ", ") + " or \(last)"
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(
            get: { text[key] ?? "" },
            set: { newValue in
                text[key] = newValue
                fieldErrors[key] = nil
                localError = nil
            }
        )
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    private func save() async {
        localError = nil
        fieldErrors = [:]
        switch schema.makeRequest(text: text, note: note) {
        case .failure(.invalid(let errors, let summary)):
            fieldErrors = errors
            localError = summary
        case .success(let request):
            let key = operation.use(request)
            let result = await model.saveReadiness(
                values: request.values,
                note: request.note,
                idempotencyKey: key
            )
            switch result {
            case .saved:
                operation.acknowledged()
                dismiss()
            case .failed(let message, let fields):
                fieldErrors = fields
                localError = message
            }
        }
    }
}
