import Foundation
import StrengthCore

/// The two HealthKit fields Phase 3A may read. No sleep, workouts, heart-rate stream or write
/// access belongs here.
enum HealthKitReadinessField: String, CaseIterable, Codable, Equatable {
    case hrvMs = "hrv_ms"
    case rhrBpm = "rhr_bpm"
    case bodyweightKg = "bodyweight_kg"

    var label: String {
        switch self {
        case .hrvMs: return "HRV"
        case .rhrBpm: return "Resting HR"
        case .bodyweightKg: return "Bodyweight"
        }
    }

    var unitLabel: String {
        switch self {
        case .hrvMs: return "ms"
        case .rhrBpm: return "bpm"
        case .bodyweightKg: return "kg"
        }
    }
}

enum HealthKitSourceClass: String, Codable, Equatable {
    case appleWatch = "apple_watch"
    case nonAppleWatch = "non_apple_watch"
    case unknown
}

/// Deterministic classification from HKDevice metadata. A display name is never accepted as
/// proof: "Apple Watch" with no device metadata stays unknown.
enum HealthKitSourceClassifier {
    private static let watchPattern = #"^Watch[0-9]+,[0-9]+$"#

    static func classify(manufacturer: String?, model: String?) -> HealthKitSourceClass {
        let maker = normalized(manufacturer)
        let hardware = normalized(model)
        guard let maker else { return .unknown }
        let isApple = maker.caseInsensitiveCompare("Apple") == .orderedSame
            || maker.caseInsensitiveCompare("Apple Inc.") == .orderedSame
        guard isApple else { return .nonAppleWatch }
        guard let hardware else { return .unknown }
        return hardware.range(of: watchPattern, options: .regularExpression) != nil
            ? .appleWatch
            : .nonAppleWatch
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct HealthKitReadinessObservation: Equatable {
    let field: HealthKitReadinessField
    let value: Double
    let sampleID: String
    let sampleAt: Date
    let sourceName: String
    let sourceBundleID: String?
    let sourceClass: HealthKitSourceClass
    let sourceModel: String?
    let sourceManufacturer: String?

    var payload: HealthKitReadinessSample {
        HealthKitReadinessSample(
            field: field.rawValue,
            value: value,
            sampleId: sampleID,
            sampleAt: Self.iso8601(sampleAt),
            sourceName: sourceName,
            sourceBundleId: sourceBundleID,
            sourceClass: sourceClass.rawValue,
            sourceModel: sourceModel,
            sourceManufacturer: sourceManufacturer
        )
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

enum HealthKitMetricStatus: Equatable {
    case eligible
    case missing
    case stale
}

struct HealthKitReadinessSelection: Equatable {
    let hrv: HealthKitReadinessObservation?
    let rhr: HealthKitReadinessObservation?
    let bodyweight: HealthKitReadinessObservation?
    let staleFields: Set<HealthKitReadinessField>
    let metricStates: [HealthKitReadinessField: HealthKitMetricStatus]

    init(
        hrv: HealthKitReadinessObservation?,
        rhr: HealthKitReadinessObservation?,
        bodyweight: HealthKitReadinessObservation? = nil,
        staleFields: Set<HealthKitReadinessField>,
        metricStates: [HealthKitReadinessField: HealthKitMetricStatus]? = nil
    ) {
        self.hrv = hrv
        self.rhr = rhr
        self.bodyweight = bodyweight
        self.staleFields = staleFields
        self.metricStates = metricStates ?? [
            .hrvMs: hrv != nil ? .eligible : (staleFields.contains(.hrvMs) ? .stale : .missing),
            .rhrBpm: rhr != nil ? .eligible : (staleFields.contains(.rhrBpm) ? .stale : .missing),
            .bodyweightKg: bodyweight != nil
                ? .eligible
                : (staleFields.contains(.bodyweightKg) ? .stale : .missing),
        ]
    }

    var isEmpty: Bool { hrv == nil && rhr == nil && bodyweight == nil }
    var hasStaleSample: Bool { !staleFields.isEmpty }

    var observations: [HealthKitReadinessObservation] {
        [hrv, rhr, bodyweight].compactMap { $0 }
    }

    func status(for field: HealthKitReadinessField) -> HealthKitMetricStatus {
        metricStates[field] ?? .missing
    }

    /// Pick at most one eligible sample per field. Apple Watch wins only when positively
    /// classified; otherwise the newest eligible sample wins, with deterministic ties.
    static func make(
        hrvCandidates: [HealthKitReadinessObservation],
        rhrCandidates: [HealthKitReadinessObservation],
        bodyweightCandidates: [HealthKitReadinessObservation] = [],
        serverDate: String,
        now: Date
    ) -> HealthKitReadinessSelection {
        let hrvEligible = hrvCandidates.filter { isEligible($0, serverDate: serverDate, now: now) }
        let rhrEligible = rhrCandidates.filter { isEligible($0, serverDate: serverDate, now: now) }
        let bodyweightEligible = bodyweightCandidates.filter {
            isEligible($0, serverDate: serverDate, now: now)
        }
        var stale: Set<HealthKitReadinessField> = []
        if !hrvCandidates.isEmpty && hrvEligible.isEmpty { stale.insert(.hrvMs) }
        if !rhrCandidates.isEmpty && rhrEligible.isEmpty { stale.insert(.rhrBpm) }
        if !bodyweightCandidates.isEmpty && bodyweightEligible.isEmpty {
            stale.insert(.bodyweightKg)
        }
        let selectedHrv = choose(hrvEligible)
        let selectedRhr = choose(rhrEligible)
        let selectedBodyweight = choose(bodyweightEligible)
        var states: [HealthKitReadinessField: HealthKitMetricStatus] = [:]
        for field in HealthKitReadinessField.allCases {
            let selected: HealthKitReadinessObservation?
            let candidates: [HealthKitReadinessObservation]
            switch field {
            case .hrvMs:
                selected = selectedHrv
                candidates = hrvCandidates
            case .rhrBpm:
                selected = selectedRhr
                candidates = rhrCandidates
            case .bodyweightKg:
                selected = selectedBodyweight
                candidates = bodyweightCandidates
            }
            if selected != nil {
                states[field] = .eligible
            } else if candidates.isEmpty {
                states[field] = .missing
            } else {
                states[field] = .stale
            }
        }
        return HealthKitReadinessSelection(
            hrv: selectedHrv,
            rhr: selectedRhr,
            bodyweight: selectedBodyweight,
            staleFields: stale,
            metricStates: states
        )
    }

    private static func isEligible(
        _ observation: HealthKitReadinessObservation,
        serverDate: String,
        now: Date
    ) -> Bool {
        guard observation.value.isFinite, observation.value > 0 else { return false }
        guard observation.sampleAt <= now.addingTimeInterval(5 * 60) else { return false }
        switch observation.field {
        case .hrvMs:
            return now.timeIntervalSince(observation.sampleAt) <= 48 * 60 * 60
        case .rhrBpm:
            return localDateString(observation.sampleAt) == serverDate
        case .bodyweightKg:
            return now.timeIntervalSince(observation.sampleAt) <= 30 * 24 * 60 * 60
        }
    }

    private static func choose(
        _ candidates: [HealthKitReadinessObservation]
    ) -> HealthKitReadinessObservation? {
        guard !candidates.isEmpty else { return nil }
        let appleWatch = candidates.filter { $0.sourceClass == .appleWatch }
        let pool = appleWatch.isEmpty ? candidates : appleWatch
        return pool.sorted {
            if $0.sampleAt != $1.sampleAt { return $0.sampleAt > $1.sampleAt }
            return $0.sampleID < $1.sampleID
        }.first
    }

    private static func localDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

enum HealthKitReadinessState: Equatable {
    case featureDisabled
    case unavailable
    case enabled
    case noEligibleSample
    case eligibleSample
    case staleSample
    case importError(String)

    var message: String? {
        switch self {
        case .featureDisabled:
            return "HealthKit readiness is off."
        case .unavailable:
            return "HealthKit is not available on this device."
        case .enabled:
            return "HealthKit is enabled. Import a sample when you are ready."
        case .noEligibleSample:
            return "No eligible HealthKit sample was returned. This can mean no data or that read access was not granted."
        case .eligibleSample:
            return "One or more HealthKit samples are available."
        case .staleSample:
            return "The HealthKit sample is outside the accepted window."
        case .importError(let message):
            return message
        }
    }
}

enum HealthKitReadinessError: LocalizedError {
    case unavailable
    case query(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "HealthKit is not available on this device."
        case .query(let message):
            return message
        }
    }
}

protocol HealthKitReadinessProviding {
    var isAvailable: Bool { get }
    func requestAuthorization() async throws
    func selectSamples(serverDate: String, now: Date) async throws -> HealthKitReadinessSelection
}

