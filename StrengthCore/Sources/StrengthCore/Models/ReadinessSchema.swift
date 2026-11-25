import Foundation

/// One readiness input from the server's effective registry.
///
/// The server owns label, scale, direction and unit (via `metric_definition`) and the operational
/// fields (role, order, weight, baseline). The client only renders and submits these values; it
/// does not compute or reinterpret readiness.
public struct ReadinessMetric: Codable, Equatable, Sendable {
    public let key: String
    public let label: String
    public let role: String
    public let enabled: Bool
    public let weight: Double
    public let baselineDays: Int
    public let countsAsCore: Bool
    public let order: Int
    public let minReadings: Int?
    public let slope: Double?
    public let scaleMin: Double?
    public let scaleMax: Double?
    public let higherIsBetter: Bool
    public let unit: String?

    public init(
        key: String,
        label: String,
        role: String,
        enabled: Bool,
        weight: Double,
        baselineDays: Int,
        countsAsCore: Bool,
        order: Int,
        minReadings: Int? = nil,
        slope: Double? = nil,
        scaleMin: Double? = nil,
        scaleMax: Double? = nil,
        higherIsBetter: Bool,
        unit: String? = nil
    ) {
        self.key = key
        self.label = label
        self.role = role
        self.enabled = enabled
        self.weight = weight
        self.baselineDays = baselineDays
        self.countsAsCore = countsAsCore
        self.order = order
        self.minReadings = minReadings
        self.slope = slope
        self.scaleMin = scaleMin
        self.scaleMax = scaleMax
        self.higherIsBetter = higherIsBetter
        self.unit = unit
    }

    public var isCore: Bool { role == "core" }
    public var isDevice: Bool { role == "device" }
    public var directionText: String { higherIsBetter ? "higher is better" : "lower is better" }

    /// A short hint built from the server's scale and direction. Never used for scoring.
    public var inputHint: String {
        if isCore {
            let low = scaleMin ?? 1
            let high = scaleMax ?? 5
            return "\(Self.format(low))–\(Self.format(high)) · \(directionText)"
        }
        if let unit, !unit.isEmpty {
            return "\(unit) · \(directionText)"
        }
        return directionText
    }

    /// Placeholder for the numeric field, using the server's unit when it provides one.
    public var inputPlaceholder: String {
        if isCore {
            let low = scaleMin ?? 1
            let high = scaleMax ?? 5
            return "\(Self.format(low))–\(Self.format(high))"
        }
        return unit ?? "value"
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

/// The date-effective readiness registry schema served by
/// `GET /api/ios/v1/readiness/schema`.
public struct ReadinessSchema: Codable, Equatable, Sendable {
    public let registryId: Int?
    public let effectiveFrom: String?
    public let schemaVersion: Int
    public let minCoreFields: Int
    public let requireAnyOf: [String]
    public let wearableWeight: Double
    public let metrics: [ReadinessMetric]

    public init(
        registryId: Int?,
        effectiveFrom: String?,
        schemaVersion: Int,
        minCoreFields: Int,
        requireAnyOf: [String],
        wearableWeight: Double,
        metrics: [ReadinessMetric]
    ) {
        self.registryId = registryId
        self.effectiveFrom = effectiveFrom
        self.schemaVersion = schemaVersion
        self.minCoreFields = minCoreFields
        self.requireAnyOf = requireAnyOf
        self.wearableWeight = wearableWeight
        self.metrics = metrics
    }

    /// Enabled metrics in registry order.
    public var enabledMetrics: [ReadinessMetric] {
        metrics.filter(\.enabled).sorted { $0.order < $1.order }
    }

    public var enabledCoreMetrics: [ReadinessMetric] {
        enabledMetrics.filter(\.isCore)
    }

    public var enabledDeviceMetrics: [ReadinessMetric] {
        enabledMetrics.filter(\.isDevice)
    }

    public func metric(_ key: String) -> ReadinessMetric? {
        metrics.first { $0.key == key }
    }

    public func isRequiredOneOf(_ metric: ReadinessMetric) -> Bool {
        requireAnyOf.contains(metric.key)
    }

    public var requiredMetricLabels: [String] {
        requireAnyOf.compactMap { metric($0)?.label }
    }

    /// The values map the server accepts: enabled registry metrics plus the two non-registry
    /// inputs. Disabled or unknown fields are never submitted.
    public func submissionValues(_ values: [String: Double]) -> [String: Double] {
        let allowed = Set(enabledMetrics.map(\.key)).union(Self.extraInputKeys)
        return values.filter { allowed.contains($0.key) }
    }

    /// The two inputs the server still stores with readiness but does not read from the registry.
    public static let extraInputKeys: Set<String> = ["bodyweight_kg", "wearable_score"]

    /// The fixed fallback used when the schema has never been cached and the server is
    /// unreachable. It mirrors the seeded registry v1 (labels, scale, direction and unit), so the
    /// athlete can still log readiness offline. It is a form fallback, not a score input.
    public static let fallback = ReadinessSchema(
        registryId: nil,
        effectiveFrom: nil,
        schemaVersion: 1,
        minCoreFields: 3,
        requireAnyOf: ["sleep", "energy"],
        wearableWeight: 0.10,
        metrics: [
            ReadinessMetric(
                key: "sleep", label: "Sleep", role: "core", enabled: true, weight: 1,
                baselineDays: 0, countsAsCore: true, order: 1,
                scaleMin: 1, scaleMax: 5, higherIsBetter: true
            ),
            ReadinessMetric(
                key: "energy", label: "Energy", role: "core", enabled: true, weight: 1,
                baselineDays: 0, countsAsCore: true, order: 2,
                scaleMin: 1, scaleMax: 5, higherIsBetter: true
            ),
            ReadinessMetric(
                key: "mood", label: "Mood", role: "core", enabled: true, weight: 1,
                baselineDays: 0, countsAsCore: true, order: 3,
                scaleMin: 1, scaleMax: 5, higherIsBetter: true
            ),
            ReadinessMetric(
                key: "stress", label: "Stress", role: "core", enabled: true, weight: 1,
                baselineDays: 0, countsAsCore: true, order: 4,
                scaleMin: 1, scaleMax: 5, higherIsBetter: true
            ),
            ReadinessMetric(
                key: "soreness", label: "Soreness", role: "core", enabled: true, weight: 1,
                baselineDays: 0, countsAsCore: true, order: 5,
                scaleMin: 1, scaleMax: 5, higherIsBetter: true
            ),
            ReadinessMetric(
                key: "hrv_ms", label: "HRV (SDNN)", role: "device", enabled: true, weight: 0.5,
                baselineDays: 28, countsAsCore: false, order: 6, minReadings: 7, slope: 0.5,
                scaleMin: 0, scaleMax: nil, higherIsBetter: true, unit: "ms"
            ),
            ReadinessMetric(
                key: "rhr_bpm", label: "Resting heart rate", role: "device", enabled: true,
                weight: 0.5, baselineDays: 28, countsAsCore: false, order: 7,
                minReadings: 7, slope: 0.5, scaleMin: 0, scaleMax: nil,
                higherIsBetter: false, unit: "bpm"
            ),
        ]
    )
}

/// Where the form's schema came from. The UI must say when it is not the live server one, because
/// a metric added to the registry after the cache was written cannot be entered offline.
public enum ReadinessSchemaSource: String, Codable, Equatable, Sendable {
    case server
    case cache
    case fallback
}

public struct ReadinessValidation: Equatable, Sendable {
    public let fieldErrors: [String: String]
    public let summary: String?

    public init(fieldErrors: [String: String] = [:], summary: String? = nil) {
        self.fieldErrors = fieldErrors
        self.summary = summary
    }

    public var isValid: Bool { fieldErrors.isEmpty && summary == nil }
}

public enum ReadinessFormError: Error, Equatable, Sendable {
    case invalid(fieldErrors: [String: String], summary: String?)
}

extension ReadinessSchema {
    /// Client-side convenience validation. The server remains authoritative: the request is still
    /// submitted and any server field errors replace these on the matching inputs.
    public func validate(values: [String: Double]) -> ReadinessValidation {
        var fieldErrors: [String: String] = [:]
        for (key, value) in values {
            if let definition = metric(key) {
                guard definition.enabled else {
                    fieldErrors[key] = "This metric is disabled in the current registry."
                    continue
                }
                if definition.isCore {
                    let low = definition.scaleMin ?? 1
                    let high = definition.scaleMax ?? 5
                    if !value.isFinite || value != value.rounded() || value < low || value > high {
                        fieldErrors[key] =
                            "Enter a whole number from \(Self.format(low)) to \(Self.format(high))."
                    }
                } else if !value.isFinite || value <= 0 {
                    fieldErrors[key] = "Enter a number greater than 0."
                }
                continue
            }
            switch key {
            case "bodyweight_kg":
                if !value.isFinite || value <= 0 {
                    fieldErrors[key] = "Enter a number greater than 0."
                }
            case "wearable_score":
                if !value.isFinite || value < 0 || value > 100 {
                    fieldErrors[key] = "Enter a number from 0 to 100."
                }
            default:
                fieldErrors[key] = "Not in the current readiness schema."
            }
        }

        guard !values.isEmpty else {
            return ReadinessValidation(
                fieldErrors: fieldErrors,
                summary: "Enter at least one readiness field."
            )
        }

        var summaries: [String] = []
        let coreKeys = Set(enabledCoreMetrics.map(\.key))
        let providedCore = Set(values.keys).intersection(coreKeys).count
        if providedCore < minCoreFields {
            summaries.append(
                "Enter at least \(minCoreFields) core fields for a score; "
                    + "\(providedCore) entered."
            )
        }
        if !requireAnyOf.isEmpty,
           Set(values.keys).isDisjoint(with: Set(requireAnyOf)) {
            let labels = requiredMetricLabels
            let names = labels.isEmpty ? requireAnyOf.joined(separator: ", ") : Self.list(labels)
            summaries.append("Enter at least one of \(names).")
        }
        return ReadinessValidation(
            fieldErrors: fieldErrors,
            summary: summaries.isEmpty ? nil : summaries.joined(separator: " ")
        )
    }

    /// Parse the form's text into the exact `{values, note}` request. Empty inputs are omitted;
    /// invalid numbers and required/minimum failures come back as field errors and a summary.
    public func makeRequest(
        text: [String: String],
        note: String
    ) -> Result<ReadinessWriteRequest, ReadinessFormError> {
        var values: [String: Double] = [:]
        var parseErrors: [String: String] = [:]

        for metric in enabledMetrics {
            guard let raw = Self.trimmed(text[metric.key]), !raw.isEmpty else { continue }
            guard let number = Self.number(raw) else {
                parseErrors[metric.key] = "Enter a number."
                continue
            }
            values[metric.key] = number
        }
        for key in Self.extraInputKeys.sorted() {
            guard let raw = Self.trimmed(text[key]), !raw.isEmpty else { continue }
            guard let number = Self.number(raw) else {
                parseErrors[key] = "Enter a number."
                continue
            }
            values[key] = number
        }

        let validation = validate(values: values)
        let fieldErrors = parseErrors.merging(validation.fieldErrors) { parse, _ in parse }
        if !fieldErrors.isEmpty || validation.summary != nil {
            return .failure(.invalid(fieldErrors: fieldErrors, summary: validation.summary))
        }
        let trimmedNote = Self.trimmed(note) ?? ""
        let request = ReadinessWriteRequest(
            values: values,
            note: trimmedNote.isEmpty ? nil : trimmedNote
        )
        return .success(request)
    }

    private static func trimmed(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func number(_ raw: String) -> Double? {
        let normalised = raw.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalised), value.isFinite else { return nil }
        return value
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private static func list(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        if items.count == 1 { return last }
        if items.count == 2 { return "\(items[0]) or \(last)" }
        return items.dropLast().joined(separator: ", ") + " or \(last)"
    }
}
