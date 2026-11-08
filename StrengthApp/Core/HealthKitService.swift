import Foundation
import HealthKit

/// Read-only HealthKit adapter. It performs no writes, no observer queries and no background
/// delivery. Query failures are surfaced; an empty result is never interpreted as denied access.
final class HealthKitReadinessService: HealthKitReadinessProviding {
    private let store: HKHealthStore

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func requestAuthorization() async throws {
        guard isAvailable else { throw HealthKitReadinessError.unavailable }
        guard let hrv = HKObjectType.quantityType(
            forIdentifier: .heartRateVariabilitySDNN
        ), let rhr = HKObjectType.quantityType(
            forIdentifier: .restingHeartRate
        ), let bodyMass = HKObjectType.quantityType(
            forIdentifier: .bodyMass
        ) else {
            throw HealthKitReadinessError.unavailable
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.requestAuthorization(toShare: [], read: [hrv, rhr, bodyMass]) { _, error in
                if let error {
                    continuation.resume(throwing: HealthKitReadinessError.query(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func selectSamples(serverDate: String, now: Date) async throws -> HealthKitReadinessSelection {
        guard isAvailable else { throw HealthKitReadinessError.unavailable }
        let end = now.addingTimeInterval(5 * 60)
        let start = now.addingTimeInterval(-30 * 24 * 60 * 60)
        async let hrvSamples = samples(
            identifier: .heartRateVariabilitySDNN, start: start, end: end
        )
        async let rhrSamples = samples(
            identifier: .restingHeartRate, start: start, end: end
        )
        async let bodyweightSamples = samples(
            identifier: .bodyMass, start: start, end: end
        )
        let (hrvRaw, rhrRaw, bodyweightRaw) = try await (
            hrvSamples, rhrSamples, bodyweightSamples
        )
        let hrv = hrvRaw.compactMap { observation($0, field: .hrvMs, serverDate: serverDate) }
        let rhr = rhrRaw.compactMap { observation($0, field: .rhrBpm, serverDate: serverDate) }
        let bodyweight = bodyweightRaw.compactMap {
            observation($0, field: .bodyweightKg, serverDate: serverDate)
        }
        return HealthKitReadinessSelection.make(
            hrvCandidates: hrv,
            rhrCandidates: rhr,
            bodyweightCandidates: bodyweight,
            serverDate: serverDate,
            now: now
        )
    }

    private func samples(
        identifier: HKQuantityTypeIdentifier,
        start: Date,
        end: Date
    ) async throws -> [HKQuantitySample] {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else {
            throw HealthKitReadinessError.unavailable
        }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(
                        throwing: HealthKitReadinessError.query(error.localizedDescription)
                    )
                    return
                }
                continuation.resume(returning: samples as? [HKQuantitySample] ?? [])
            }
            store.execute(query)
        }
    }

    private func observation(
        _ sample: HKQuantitySample,
        field: HealthKitReadinessField,
        serverDate: String
    ) -> HealthKitReadinessObservation? {
        let unit: HKUnit
        switch field {
        case .hrvMs:
            unit = HKUnit.secondUnit(with: .milli)
        case .rhrBpm:
            unit = HKUnit.count().unitDivided(by: HKUnit.minute())
        case .bodyweightKg:
            unit = HKUnit.gramUnit(with: .kilo)
        }
        let value = sample.quantity.doubleValue(for: unit)
        guard value.isFinite, value > 0 else { return nil }
        let source = sample.sourceRevision.source
        let device = sample.device
        let sourceClass = HealthKitSourceClassifier.classify(
            manufacturer: device?.manufacturer,
            model: device?.model
        )
        let sampleAt: Date
        switch field {
        case .hrvMs:
            sampleAt = sample.endDate
        case .rhrBpm:
            let startDate = localDateString(sample.startDate)
            let endDate = localDateString(sample.endDate)
            if startDate == serverDate {
                sampleAt = sample.startDate
            } else if endDate == serverDate {
                sampleAt = sample.endDate
            } else {
                sampleAt = sample.endDate
            }
        case .bodyweightKg:
            sampleAt = sample.endDate
        }
        return HealthKitReadinessObservation(
            field: field,
            value: value,
            sampleID: sample.uuid.uuidString,
            sampleAt: sampleAt,
            sourceName: source.name,
            sourceBundleID: source.bundleIdentifier,
            sourceClass: sourceClass,
            sourceModel: device?.model,
            sourceManufacturer: device?.manufacturer
        )
    }

    private func localDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
