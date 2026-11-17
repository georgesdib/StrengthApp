import Foundation
import HealthKit
import StrengthCore

enum HealthKitActivityError: LocalizedError {
    case unavailable
    case denied
    case query(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Health data is not available on this device."
        case .denied: return "Health access was not granted for workouts and heart rate."
        case .query(let message): return message
        }
    }
}

protocol HealthKitActivityProviding {
    var isAvailable: Bool { get }
    var lastSyncedAt: Date { get }
    func requestAuthorization() async throws
    var lastWorkoutAt: Date { get }
    func fetchBatch(now: Date) async throws -> HealthKitActivityBatch
    func markSynced(now: Date, workouts: [HealthKitActivityWorkout])
}

/// Reads the incremental slice of HealthKit activity: workouts after the export cutoff, and the
/// heart-rate samples that belong to them or to their ten-minute recovery tail.
///
/// The export promoted history up to `2026-11-17T17:49:23Z`, so the first run starts a week before
/// that date and every run after it starts a week before the last success. The lookback is
/// deliberate: a sample can arrive after the sync that should have carried it, and re-sending is
/// idempotent while missing one is not.
final class HealthKitActivityService: HealthKitActivityProviding {
    static let defaultCutoff = ISO8601DateFormatter().date(from: "2026-11-17T17:49:23Z") ?? Date()

    private let store = HKHealthStore()
    private let defaults: UserDefaults
    private let sampleCursorKey = "healthkit.activity.samplesSyncedAt.v2"
    private let workoutCursorKey = "healthkit.activity.workoutsSyncedAt.v2"
    private let lookback: TimeInterval = 7 * 24 * 60 * 60
    private let tail: TimeInterval = 600

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    var lastSyncedAt: Date {
        (defaults.object(forKey: sampleCursorKey) as? Date) ?? Self.defaultCutoff
    }

    /// The workouts cursor advances only to the latest workout actually uploaded. Advancing it to
    /// "now" would skip a workout that ended before the sync began, which is exactly how the
    /// 17 November session was lost.
    var lastWorkoutAt: Date {
        (defaults.object(forKey: workoutCursorKey) as? Date) ?? Self.defaultCutoff
    }

    func markSynced(now: Date, workouts: [HealthKitActivityWorkout]) {
        defaults.set(now, forKey: sampleCursorKey)
        let formatter = ISO8601DateFormatter()
        if let latest = workouts.compactMap({ formatter.date(from: $0.endedAt) }).max() {
            defaults.set(latest, forKey: workoutCursorKey)
        }
    }

    func requestAuthorization() async throws {
        guard isAvailable else { throw HealthKitActivityError.unavailable }
        guard let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate) else {
            throw HealthKitActivityError.unavailable
        }
        var read: Set<HKObjectType> = [HKObjectType.workoutType(), heartRate]
        if let vo2max = HKObjectType.quantityType(forIdentifier: .vo2Max) { read.insert(vo2max) }
        if let effort = HKObjectType.quantityType(forIdentifier: .workoutEffortScore) {
            read.insert(effort)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.requestAuthorization(toShare: [], read: read) { _, error in
                if let error {
                    continuation.resume(throwing: HealthKitActivityError.query(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func fetchBatch(now: Date = Date()) async throws -> HealthKitActivityBatch {
        guard isAvailable else { throw HealthKitActivityError.unavailable }
        // Workouts never need a lookback: anything before the export cutoff is already in the
        // database under a content key, and re-uploading it here would create a second row for the
        // same session (the mistake this filter exists to prevent). The lookback belongs to samples
        // only, and samples are filtered by the intervals of the workouts fetched in this run.
        // One day of overlap on workouts: cheap because uploads are idempotent, and it covers a
        // workout that ended just before the previous cursor advanced.
        let workoutStart = max(
            lastWorkoutAt.addingTimeInterval(-24 * 60 * 60),
            Self.defaultCutoff
        )
        let efforts = try await fetchEffortScores(since: workoutStart)
        let workouts = try await fetchWorkouts(since: workoutStart, efforts: efforts)
        let formatter = ISO8601DateFormatter()
        let intervals = workouts.compactMap {
            workout -> (key: String, start: Date, workoutEnd: Date, end: Date)? in
            guard let end = formatter.date(from: workout.endedAt),
                  let begin = formatter.date(from: workout.startedAt)
            else { return nil }
            return (workout.key, begin, end, end.addingTimeInterval(tail))
        }
        let sampleStart = lastSyncedAt.addingTimeInterval(-lookback)
        let samples = try await fetchHeartRate(since: sampleStart, intervals: intervals)
        let metrics = try await fetchMetrics(since: max(lastSyncedAt, Self.defaultCutoff))
        return HealthKitActivityBatch(workouts: workouts, samples: samples, metrics: metrics)
    }

    // MARK: - Queries

    /// Apple relates an effort sample to its workout rather than nesting it, so the value is matched
    /// by falling inside the workout's interval. Only workouts this sync is uploading get one.
    private func fetchEffortScores(since: Date) async throws -> [(start: Date, end: Date, value: Double)] {
        guard let type = HKQuantityType.quantityType(forIdentifier: .workoutEffortScore) else {
            return []
        }
        let predicate = HKQuery.predicateForSamples(withStart: since, end: nil, options: [])
        let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, results, error in
                if let error {
                    continuation.resume(throwing: HealthKitActivityError.query(error.localizedDescription))
                } else {
                    continuation.resume(returning: results as? [HKQuantitySample] ?? [])
                }
            }
            store.execute(query)
        }
        return samples.compactMap { sample in
            let value = sample.quantity.doubleValue(for: .appleEffortScore())
            guard value.isFinite, (1...10).contains(value) else { return nil }
            return (sample.startDate, sample.endDate, value)
        }
    }

    private func fetchWorkouts(
        since: Date,
        efforts: [(start: Date, end: Date, value: Double)]
    ) async throws -> [HealthKitActivityWorkout] {
        let predicate = HKQuery.predicateForSamples(withStart: since, end: nil, options: [])
        let samples: [HKWorkout] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, results, error in
                if let error {
                    continuation.resume(throwing: HealthKitActivityError.query(error.localizedDescription))
                } else {
                    continuation.resume(returning: results as? [HKWorkout] ?? [])
                }
            }
            store.execute(query)
        }
        return samples.map { workout in
            let heartRate = workout.statistics(for: HKQuantityType(.heartRate))
            let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))
            // Apple's own MET value travels in metadata, not in statistics: the export had it for
            // 80% of strength workouts, and health-rate classification is only the fallback.
            let mets = (workout.metadata?[HKMetadataKeyAverageMETs] as? HKQuantity)?
                .doubleValue(for: Self.metsUnit)
            return HealthKitActivityWorkout(
                key: workout.uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                activityType: Self.activityName(workout.workoutActivityType),
                startedAt: HealthKitActivityFormat.iso(workout.startDate),
                endedAt: HealthKitActivityFormat.iso(workout.endDate),
                durationS: max(Int(workout.duration.rounded()), 1),
                sourceName: workout.sourceRevision.source.name,
                avgHeartRate: heartRate?.averageQuantity().map { Int($0.doubleValue(for: Self.bpm).rounded()) },
                maxHeartRate: heartRate?.maximumQuantity().map { Int($0.doubleValue(for: Self.bpm).rounded()) },
                activeEnergyKj: energy?.sumQuantity().map { $0.doubleValue(for: .kilocalorie()) * 4.184 },
                distanceM: workout.totalDistance.map { $0.doubleValue(for: .meter()) },
                avgMets: mets,
                srpe: efforts.first {
                    $0.start >= workout.startDate.addingTimeInterval(-60)
                        && $0.end <= workout.endDate.addingTimeInterval(60)
                }?.value,
                timezone: nil
            )
        }
    }

    private func fetchHeartRate(
        since: Date,
        intervals: [(key: String, start: Date, workoutEnd: Date, end: Date)]
    ) async throws -> [HealthKitActivitySample] {
        guard !intervals.isEmpty, let type = HKObjectType.quantityType(forIdentifier: .heartRate) else {
            return []
        }
        let predicate = HKQuery.predicateForSamples(withStart: since, end: nil, options: [])
        let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, results, error in
                if let error {
                    continuation.resume(throwing: HealthKitActivityError.query(error.localizedDescription))
                } else {
                    continuation.resume(returning: results as? [HKQuantitySample] ?? [])
                }
            }
            store.execute(query)
        }
        return samples.compactMap { sample in
            guard let match = intervals.first(where: { $0.start <= sample.startDate && sample.startDate <= $0.end })
            else { return nil }
            let value = sample.quantity.doubleValue(for: Self.bpm)
            guard value.isFinite, (20...260).contains(value) else { return nil }
            return HealthKitActivitySample(
                key: sample.uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                workoutKey: match.key,
                kind: "heart_rate",
                sampledAt: HealthKitActivityFormat.iso(sample.startDate),
                value: value,
                unit: "count/min",
                association: sample.startDate <= match.workoutEnd ? "workout" : "tail",
                sourceName: sample.sourceRevision.source.name
            )
        }
    }

    /// VO2max arrives as a standalone quantity sample, so it is filtered at the cutoff: anything
    /// earlier already exists in `measurement` from the export, under a different key.
    private func fetchMetrics(since: Date) async throws -> [HealthKitActivityMetric] {
        guard let type = HKQuantityType.quantityType(forIdentifier: .vo2Max) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: since, end: nil, options: [])
        let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, results, error in
                if let error {
                    continuation.resume(throwing: HealthKitActivityError.query(error.localizedDescription))
                } else {
                    continuation.resume(returning: results as? [HKQuantitySample] ?? [])
                }
            }
            store.execute(query)
        }
        return samples.compactMap { sample in
            let value = sample.quantity.doubleValue(for: Self.vo2maxUnit)
            guard value.isFinite, (5...90).contains(value) else { return nil }
            return HealthKitActivityMetric(
                key: sample.uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                kind: "vo2max",
                measuredAt: HealthKitActivityFormat.iso(sample.startDate),
                value: value,
                method: sample.sourceRevision.source.name
            )
        }
    }

    private static let vo2maxUnit = HKUnit.literUnit(with: .milli)
        .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: HKUnit.minute()))
    private static let bpm = HKUnit.count().unitDivided(by: HKUnit.minute())
    private static let metsUnit = HKUnit.kilocalorie().unitDivided(
        by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: HKUnit.hour())
    )

    /// The server matches strength workouts by HealthKit's own activity name, so the raw enum has to
    /// be translated; an unknown case is `Other` rather than a guess.
    static func activityName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .traditionalStrengthTraining: return "HKWorkoutActivityTypeTraditionalStrengthTraining"
        case .functionalStrengthTraining: return "HKWorkoutActivityTypeFunctionalStrengthTraining"
        case .running: return "HKWorkoutActivityTypeRunning"
        case .cycling: return "HKWorkoutActivityTypeCycling"
        case .walking: return "HKWorkoutActivityTypeWalking"
        case .swimming: return "HKWorkoutActivityTypeSwimming"
        case .hiking: return "HKWorkoutActivityTypeHiking"
        case .highIntensityIntervalTraining: return "HKWorkoutActivityTypeHighIntensityIntervalTraining"
        case .golf: return "HKWorkoutActivityTypeGolf"
        case .tennis: return "HKWorkoutActivityTypeTennis"
        case .yoga: return "HKWorkoutActivityTypeYoga"
        default: return "HKWorkoutActivityTypeOther"
        }
    }
}
