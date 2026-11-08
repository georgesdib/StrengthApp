import Foundation

/// The two HealthKit fields Phase 3A may read. No sleep, workouts, heart-rate stream or write
/// access belongs here.
enum HealthKitReadinessField: String, CaseIterable, Codable, Equatable {
    case hrvMs = "hrv_ms"
    case rhrBpm = "rhr_bpm"

    var label: String {
        switch self {
        case .hrvMs: return "HRV"
        case .rhrBpm: return "Resting HR"
        }
    }

    var unitLabel: String {
        switch self {
        case .hrvMs: return "ms"
        case .rhrBpm: return "bpm"
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

struct HealthKitReadinessSelection: Equatable {
    let hrv: HealthKitReadinessObservation?
    let rhr: HealthKitReadinessObservation?
    let staleFields: Set<HealthKitReadinessField>

    var isEmpty: Bool { hrv == nil && rhr == nil }
    var hasStaleSample: Bool { !staleFields.isEmpty }

    var observations: [HealthKitReadinessObservation] {
        [hrv, rhr].compactMap { $0 }
    }

    /// Pick at most one eligible sample per field. Apple Watch wins only when positively
    /// classified; otherwise the newest eligible sample wins, with deterministic ties.
    static func make(
        hrvCandidates: [HealthKitReadinessObservation],
        rhrCandidates: [HealthKitReadinessObservation],
        serverDate: String,
        now: Date
    ) -> HealthKitReadinessSelection {
        let hrvEligible = hrvCandidates.filter { isEligible($0, serverDate: serverDate, now: now) }
        let rhrEligible = rhrCandidates.filter { isEligible($0, serverDate: serverDate, now: now) }
        var stale: Set<HealthKitReadinessField> = []
        if !hrvCandidates.isEmpty && hrvEligible.isEmpty { stale.insert(.hrvMs) }
        if !rhrCandidates.isEmpty && rhrEligible.isEmpty { stale.insert(.rhrBpm) }
        return HealthKitReadinessSelection(
            hrv: choose(hrvEligible),
            rhr: choose(rhrEligible),
            staleFields: stale
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
            return "A HealthKit sample is available."
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

struct HealthKitReadinessRequest: Encodable, Equatable {
    let date: String
    let samples: [HealthKitReadinessSample]
}

struct HealthKitReadinessSample: Encodable, Equatable {
    let field: String
    let value: Double
    let sampleId: String
    let sampleAt: String
    let sourceName: String
    let sourceBundleId: String?
    let sourceClass: String
    let sourceModel: String?
    let sourceManufacturer: String?
}
