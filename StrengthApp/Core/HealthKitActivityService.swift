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
        case .denied: return "Health access was not granted for workouts, heart rate, active energy and daily activity."
        case .query(let message): return message
        }
    }
}

protocol HealthKitActivityProviding {
    var isAvailable: Bool { get }
    var lastSyncedAt: Date { get }
    var lastWorkoutAt: Date { get }
    func requestAuthorization() async throws
    func fetchBatch(now: Date) async throws -> HealthKitActivityBatch
    /// Advances the workout cursor and remembers each interval for later sample association.
    /// Rejected keys are quarantined so the 24-hour overlap cannot rediscover them.
    func markWorkoutsSynced(_ workouts: [HealthKitActivityWorkout], rejectedKeys: Set<String>)
    /// Advances the heart-rate sample cursor. Rejected keys are quarantined so the seven-day
    /// overlap cannot rediscover them.
    func markSamplesSynced(at date: Date, rejectedKeys: Set<String>)
    var quarantinedWorkoutKeys: [String] { get }
    var quarantinedSampleKeys: [String] { get }
    func clearQuarantine()
}

/// A workout interval the app has uploaded. Heart-rate samples can arrive after the workout has
/// left the short workout query, so the interval is persisted and reused when associating samples.
struct HealthKitActivityInterval: Codable, Equatable {
    let key: String
    let start: Date
    let workoutEnd: Date
    let tailEnd: Date
}

/// Reads the incremental slice of HealthKit activity: workouts after the export cutoff, and the
/// heart-rate samples that belong to those workouts or to their ten-minute recovery tail.
///
/// Workouts and samples have independent cursors. Workouts use a one-day overlap because uploads
/// are idempotent; samples use a seven-day overlap because HealthKit can deliver a sample long
/// after the workout it belongs to. Crucially, sample association uses every uploaded workout
/// interval remembered in `intervalStoreKey`, not only the workouts rediscovered in this run.
final class HealthKitActivityService: HealthKitActivityProviding {
    static let defaultCutoff = ISO8601DateFormatter().date(from: "2026-11-17T17:49:23Z") ?? Date()

    private let store = HKHealthStore()
    private let defaults: UserDefaults
    private let sampleCursorKey = "healthkit.activity.samplesSyncedAt.v2"
    private let workoutCursorKey = "healthkit.activity.workoutsSyncedAt.v2"
    private let intervalStoreKey = "healthkit.activity.uploadedWorkoutIntervals.v1"
    private let workoutQuarantineKey = "healthkit.activity.quarantinedWorkoutKeys.v1"
    private let sampleQuarantineKey = "healthkit.activity.quarantinedSampleKeys.v1"
    private static let workoutQuarantineLimit = 500
    private static let sampleQuarantineLimit = 5000
    private let lookback: TimeInterval = 7 * 24 * 60 * 60
    private static let workoutOverlap: TimeInterval = 24 * 60 * 60
    private static let tail: TimeInterval = 600
    /// Enough to cover the seven-day sample window plus the recovery tail and a late sync.
    private let intervalRetention: TimeInterval = 14 * 24 * 60 * 60

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    var lastSyncedAt: Date {
        (defaults.object(forKey: sampleCursorKey) as? Date) ?? Self.defaultCutoff
    }

    /// The workouts cursor advances to the latest workout the server answered for, including a
    /// quarantined one. Advancing it to "now" would skip a workout that ended before the sync began,
    /// which is exactly how the 17 November session was lost.
    var lastWorkoutAt: Date {
        (defaults.object(forKey: workoutCursorKey) as? Date) ?? Self.defaultCutoff
    }

    var quarantinedWorkoutKeys: [String] { storedKeys(forKey: workoutQuarantineKey) }
    var quarantinedSampleKeys: [String] { storedKeys(forKey: sampleQuarantineKey) }

    /// Commit a workout upload after the server answered. Intervals are persisted only for workouts
    /// the server accepted; a rejected key is quarantined so the 24-hour overlap cannot rediscover
    /// it. The cursor still advances past the whole batch, so one bad workout cannot stall later
    /// ones. This method must not be called when the server did not identify its rejected keys.
    func markWorkoutsSynced(
        _ workouts: [HealthKitActivityWorkout],
        rejectedKeys: Set<String>
    ) {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let accepted = workouts.filter { !rejectedKeys.contains($0.key) }
        let newIntervals = accepted.compactMap {
            Self.interval(for: $0, formatter: formatter)
        }
        if !newIntervals.isEmpty {
            let merged = Self.mergedIntervals(
                knownIntervals(now: now) + newIntervals,
                now: now,
                retention: intervalRetention
            )
            if let data = try? JSONEncoder().encode(merged) {
                defaults.set(data, forKey: intervalStoreKey)
            }
        }
        if let latest = workouts.compactMap({ formatter.date(from: $0.endedAt) }).max() {
            defaults.set(latest, forKey: workoutCursorKey)
        }
        if !rejectedKeys.isEmpty {
            saveKeys(
                Self.mergedKeys(
                    rejectedKeys,
                    existing: quarantinedWorkoutKeys,
                    limit: Self.workoutQuarantineLimit
                ),
                forKey: workoutQuarantineKey
            )
        }
    }

    func markSamplesSynced(at date: Date, rejectedKeys: Set<String>) {
        defaults.set(date, forKey: sampleCursorKey)
        if !rejectedKeys.isEmpty {
            saveKeys(
                Self.mergedKeys(
                    rejectedKeys,
                    existing: quarantinedSampleKeys,
                    limit: Self.sampleQuarantineLimit
                ),
                forKey: sampleQuarantineKey
            )
        }
    }

    func clearQuarantine() {
        defaults.removeObject(forKey: workoutQuarantineKey)
        defaults.removeObject(forKey: sampleQuarantineKey)
    }

    private func storedKeys(forKey key: String) -> [String] {
        guard let data = defaults.data(forKey: key),
              let keys = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return keys
    }

    private func saveKeys(_ keys: [String], forKey key: String) {
        guard let data = try? JSONEncoder().encode(keys) else { return }
        defaults.set(data, forKey: key)
    }

    static func mergedKeys(
        _ newKeys: Set<String>,
        existing: [String],
        limit: Int
    ) -> [String] {
        var result = existing
        var seen = Set(existing)
        for key in newKeys.sorted() {
            if seen.insert(key).inserted { result.append(key) }
        }
        if result.count > limit {
            result.removeFirst(result.count - limit)
        }
        return result
    }

    /// Intervals already uploaded, newest data pruned to the sample retention window.
    func knownIntervals(now: Date = Date()) -> [HealthKitActivityInterval] {
        guard let data = defaults.data(forKey: intervalStoreKey),
              let decoded = try? JSONDecoder().decode(
                  [HealthKitActivityInterval].self, from: data
              )
        else { return [] }
        return Self.mergedIntervals(decoded, now: now, retention: intervalRetention)
    }

    static func interval(
        for workout: HealthKitActivityWorkout,
        formatter: ISO8601DateFormatter
    ) -> HealthKitActivityInterval? {
        guard let start = formatter.date(from: workout.startedAt),
              let end = formatter.date(from: workout.endedAt)
        else { return nil }
        return HealthKitActivityInterval(
            key: workout.key,
            start: start,
            workoutEnd: end,
            tailEnd: end.addingTimeInterval(tail)
        )
    }

    /// Deduplicate by HealthKit key and drop intervals too old for the sample window.
    static func mergedIntervals(
        _ intervals: [HealthKitActivityInterval],
        now: Date,
        retention: TimeInterval
    ) -> [HealthKitActivityInterval] {
        let oldest = now.addingTimeInterval(-retention)
        var byKey: [String: HealthKitActivityInterval] = [:]
        for interval in intervals where interval.tailEnd >= oldest {
            if let existing = byKey[interval.key] {
                if interval.tailEnd > existing.tailEnd { byKey[interval.key] = interval }
            } else {
                byKey[interval.key] = interval
            }
        }
        return byKey.values.sorted { $0.start < $1.start }
    }

    static func interval(
        containing date: Date,
        in intervals: [HealthKitActivityInterval]
    ) -> HealthKitActivityInterval? {
        intervals.first { $0.start <= date && date <= $0.tailEnd }
    }

    func requestAuthorization() async throws {
        guard isAvailable else { throw HealthKitActivityError.unavailable }
        guard let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate) else {
            throw HealthKitActivityError.unavailable
        }
        var read: Set<HKObjectType> = [HKObjectType.workoutType(), heartRate]
        // Workout statistics for active energy are only returned when the app may read the type.
        if let activeEnergy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) {
            read.insert(activeEnergy)
        }
        if let vo2max = HKObjectType.quantityType(forIdentifier: .vo2Max) { read.insert(vo2max) }
        // Steps and standing time feed the periodic measurement log, not readiness. They ride the
        // activity sync so the same consent switch and the same per-item tolerance cover them.
        if let steps = HKObjectType.quantityType(forIdentifier: .stepCount) { read.insert(steps) }
        if let stand = HKObjectType.quantityType(forIdentifier: .appleStandTime) { read.insert(stand) }
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
        // Never query before the export cutoff: those workouts already exist under a content key,
        // and sending them here would create a second row for the same session.
        let storedIntervals = knownIntervals(now: now)
        let sampleStart = lastSyncedAt.addingTimeInterval(-lookback)
        var workoutStart = lastWorkoutAt.addingTimeInterval(-Self.workoutOverlap)
        if storedIntervals.isEmpty {
            // No remembered intervals (first run on this build, or a cleared store). Query back to
            // the sample window once, so a heart-rate sample delivered late can still find the
            // workout it belongs to. The intervals are persisted when the workout upload succeeds.
            workoutStart = min(workoutStart, sampleStart)
        }
        workoutStart = max(workoutStart, Self.defaultCutoff)
        let quarantinedWorkouts = Set(quarantinedWorkoutKeys)
        let quarantinedSamples = Set(quarantinedSampleKeys)
        let efforts = try await fetchEffortScores(since: workoutStart)
        let fetchedWorkouts = try await fetchWorkouts(since: workoutStart, efforts: efforts)
        // The short workout overlap can rediscover a quarantined workout for a day, and the
        // seven-day sample overlap can rediscover its samples for a week. Filter both here so a
        // rejected identity is not re-sent on every sync.
        let workouts = fetchedWorkouts.filter { !quarantinedWorkouts.contains($0.key) }
        let formatter = ISO8601DateFormatter()
        let fetchedIntervals = workouts.compactMap {
            Self.interval(for: $0, formatter: formatter)
        }
        // Associate against previously uploaded workouts as well as the ones discovered now. A
        // workout uploaded on an earlier sync is outside this run's 24-hour workout overlap, but
        // its samples can still be inside the seven-day sample window.
        let intervals = Self.mergedIntervals(
            storedIntervals + fetchedIntervals,
            now: now,
            retention: intervalRetention
        )
        let samples = try await fetchHeartRate(since: sampleStart, intervals: intervals)
            .filter {
                !quarantinedSamples.contains($0.key)
                    && !quarantinedWorkouts.contains($0.workoutKey)
            }
        // Metrics are content-deduplicated on the server, so they are sent without a cutoff: that
        // lets a sync fill any gap in the exported history instead of only appending forward.
        let metrics = try await fetchMetrics()
            + fetchWindowMetrics(now: now, calendar: .current)
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
        // strictStartDate matters: without it HealthKit also returns a workout that started before
        // the cursor but overlaps it. Sending such a workout can trip the server's pre-cutoff guard
        // and put the whole workout half into a permanent rejected state.
        let predicate = HKQuery.predicateForSamples(
            withStart: since, end: nil, options: [.strictStartDate]
        )
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
        // Defence in depth: never let a pre-cutoff workout into the upload even if a query or a
        // cursor correction widens the window. The server rejects it, which would hold the cursor.
        return samples.filter { $0.startDate >= Self.defaultCutoff }.map { workout in
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
        intervals: [HealthKitActivityInterval]
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
            guard let match = Self.interval(containing: sample.startDate, in: intervals)
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
    private func fetchMetrics() async throws -> [HealthKitActivityMetric] {
        guard let type = HKQuantityType.quantityType(forIdentifier: .vo2Max) else { return [] }
        let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type, predicate: nil, limit: HKObjectQueryNoLimit,
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

    /// Steps and standing time are periodic assessments, so HealthKit is asked for daily totals
    /// over the last completed calendar week and the phone sends the mean. A day without data
    /// stays absent: an unworn watch is missing, not zero.
    private func fetchWindowMetrics(
        now: Date,
        calendar: Calendar
    ) async throws -> [HealthKitActivityMetric] {
        let window = HealthKitWindowMetric.window(now: now, calendar: calendar)
        var metrics: [HealthKitActivityMetric] = []

        if let type = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            let totals = await dailySums(
                type: type, unit: .count(), window: window, calendar: calendar
            )
            if let metric = totals.flatMap({
                HealthKitWindowMetric.stepsMetric(
                    dailyTotals: $0, window: window, calendar: calendar
                )
            }) {
                metrics.append(metric)
            }
        }
        if let type = HKQuantityType.quantityType(forIdentifier: .appleStandTime) {
            let minutes = await dailySums(
                type: type, unit: .minute(), window: window, calendar: calendar
            )
            if let metric = minutes.flatMap({
                HealthKitWindowMetric.sittingMetric(
                    dailyStandMinutes: $0, window: window, calendar: calendar
                )
            }) {
                metrics.append(metric)
            }
        }
        return metrics
    }

    /// One value per day in the window, `nil` where HealthKit holds no data.
    ///
    /// A failed query yields `nil` instead of an empty series: an access problem must stay
    /// distinguishable from a week of zero steps, and a steps failure must not cost the heart-rate
    /// samples travelling in the same sync.
    private func dailySums(
        type: HKQuantityType,
        unit: HKUnit,
        window: HealthKitWindowMetric.Window,
        calendar: Calendar
    ) async -> [Double?]? {
        let end = calendar.date(byAdding: .day, value: 1, to: window.end) ?? window.end
        let predicate = HKQuery.predicateForSamples(
            withStart: window.start, end: end, options: .strictStartDate
        )
        let query = HKStatisticsCollectionQuery(
            quantityType: type,
            quantitySamplePredicate: predicate,
            options: .cumulativeSum,
            anchorDate: window.start,
            intervalComponents: HealthKitWindowMetric.interval(window: window, calendar: calendar)
        )
        let byDay = await withCheckedContinuation { (
            continuation: CheckedContinuation<[Date: Double]?, Never>
        ) in
            query.initialResultsHandler = { _, results, error in
                guard error == nil, let results else {
                    continuation.resume(returning: nil)
                    return
                }
                var values: [Date: Double] = [:]
                results.enumerateStatistics(from: window.start, to: end) { statistics, _ in
                    if let sum = statistics.sumQuantity() {
                        values[calendar.startOfDay(for: statistics.startDate)] =
                            sum.doubleValue(for: unit)
                    }
                }
                continuation.resume(returning: .some(values))
            }
            store.execute(query)
        }
        guard let byDay else { return nil }
        return (0..<window.days).map { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: window.start) else {
                return nil
            }
            return byDay[calendar.startOfDay(for: day)]
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
        case .tableTennis: return "HKWorkoutActivityTypeTableTennis"
        case .yoga: return "HKWorkoutActivityTypeYoga"
        default: return "HKWorkoutActivityTypeOther"
        }
    }
}
