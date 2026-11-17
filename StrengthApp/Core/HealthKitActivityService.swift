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
    func fetchBatch(now: Date) async throws -> HealthKitActivityBatch
    func markSynced(_ date: Date)
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
    private let cursorKey = "healthkit.activity.syncedAt"
    private let lookback: TimeInterval = 7 * 24 * 60 * 60
    private let tail: TimeInterval = 600

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    var lastSyncedAt: Date {
        (defaults.object(forKey: cursorKey) as? Date) ?? Self.defaultCutoff
    }

    func markSynced(_ date: Date) {
        defaults.set(date, forKey: cursorKey)
    }

    func requestAuthorization() async throws {
        guard isAvailable else { throw HealthKitActivityError.unavailable }
        guard let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate) else {
            throw HealthKitActivityError.unavailable
        }
        let read: Set<HKObjectType> = [HKObjectType.workoutType(), heartRate]
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
        let workoutStart = max(lastSyncedAt, Self.defaultCutoff)
        let workouts = try await fetchWorkouts(since: workoutStart)
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
        return HealthKitActivityBatch(workouts: workouts, samples: samples)
    }

    // MARK: - Queries

    private func fetchWorkouts(since: Date) async throws -> [HealthKitActivityWorkout] {
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
                avgMets: nil,
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

    private static let bpm = HKUnit.count().unitDivided(by: HKUnit.minute())

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
