import Foundation
import StrengthCore

/// What one activity sync actually achieved.
///
/// The server accepts a batch with a 200 even when it rejected individual workouts, samples or
/// metrics, so `created`/`existing` alone cannot distinguish a complete sync from a partial one.
struct HealthKitActivitySyncReport: Equatable {
    var hadActivity = false
    var workoutsCreated = 0
    var workoutsExisting = 0
    var workoutsRejected = 0
    var samplesCreated = 0
    var samplesExisting = 0
    var samplesRejected = 0
    var metricsWritten = 0
    var metricsSkipped = 0
    /// Keys the server named as rejected. Empty when an older server only returned a count.
    var rejectedWorkoutKeys: [String] = []
    var rejectedSampleKeys: [String] = []
    /// True when a rejected workout stopped samples from being submitted in this run.
    var samplesDeferred = false
    /// Samples skipped because their workout was rejected and is now quarantined.
    var samplesSkippedForQuarantine = 0

    var isEmpty: Bool { !hadActivity }

    var isPartial: Bool {
        workoutsRejected > 0 || samplesRejected > 0 || metricsSkipped > 0
            || samplesDeferred || samplesSkippedForQuarantine > 0
    }
}

/// Stable identity of the backend database an activity sync writes to.
///
/// The pairing device id is issued by the backend database, so it is unchanged when the app moves
/// between its Home and Away routes to the same database, and different once the phone pairs with
/// another database. A base URL cannot stand in for this: Home and Away are two URLs for one
/// database, so treating a route change as a new backend would needlessly discard the cursors.
/// The URL is a defensive fallback for an unpaired session, which activity sync does not use.
enum HealthKitActivityServerIdentity {
    static func identity(for session: IOSSession) -> String {
        if let deviceID = session.deviceID?
            .trimmingCharacters(in: .whitespacesAndNewlines), !deviceID.isEmpty {
            return "device:\(deviceID)"
        }
        return "url:\(session.baseURL.absoluteString)"
    }
}

/// Orchestrates one incremental HealthKit activity sync.
///
/// The server identifies rejected items by key. Those keys are quarantined and the cursor advances
/// past them, so one immutable conflict cannot stall every later workout or sample. If an older
/// server returns only a count, the client keeps the conservative behaviour: hold the affected
/// cursor (and defer samples after a workout rejection) rather than guessing which item failed.
@MainActor
struct HealthKitActivitySync {
    private let client: IOSAPIClient
    private let activity: any HealthKitActivityProviding

    init(client: IOSAPIClient, activity: any HealthKitActivityProviding) {
        self.client = client
        self.activity = activity
    }

    func run(session: IOSSession, at now: Date = Date()) async throws -> HealthKitActivitySyncReport {
        // Scope the persisted cursors to the backend before reading or committing any of them.
        activity.prepare(for: HealthKitActivityServerIdentity.identity(for: session))
        let batch = try await activity.fetchBatch(now: now)
        var report = HealthKitActivitySyncReport()
        report.hadActivity = !batch.isEmpty

        var quarantinedWorkouts: Set<String> = []
        if !batch.workouts.isEmpty {
            let result = try await client.uploadActivity(
                HealthKitActivityWorkoutsBody(workouts: batch.workouts),
                session: session,
                idempotencyKey: UUID().uuidString
            )
            report.workoutsCreated = result.created
            report.workoutsExisting = result.existing
            report.workoutsRejected = result.rejected
            let rejected = Set(result.rejectedKeys)
            guard result.rejected == rejected.count else {
                // Count without keys: do not guess. Sending samples now could reference a workout
                // the server does not have, so the whole sample half waits with the cursor.
                report.samplesDeferred = !batch.samples.isEmpty || !batch.metrics.isEmpty
                return report
            }
            quarantinedWorkouts = rejected
            report.rejectedWorkoutKeys = rejected.sorted()
            activity.markWorkoutsSynced(batch.workouts, rejectedKeys: rejected)
        }

        // A newly rejected workout is quarantined above, but its samples were already fetched. Drop
        // them: the server requires the workout to exist before accepting its samples.
        let samples = batch.samples.filter {
            !quarantinedWorkouts.contains($0.workoutKey)
        }
        report.samplesSkippedForQuarantine = batch.samples.count - samples.count

        if !samples.isEmpty || !batch.metrics.isEmpty {
            let result = try await client.uploadActivity(
                HealthKitActivitySamplesBody(samples: samples, metrics: batch.metrics),
                session: session,
                idempotencyKey: UUID().uuidString
            )
            report.samplesCreated = result.created
            report.samplesExisting = result.existing
            report.samplesRejected = result.rejected
            report.metricsWritten = result.metrics?.written ?? 0
            report.metricsSkipped = result.skippedMetrics
            let rejected = Set(result.rejectedKeys)
            if result.rejected == rejected.count {
                report.rejectedSampleKeys = rejected.sorted()
                // Metrics have no cursor and are re-read on every sync, so a skipped VO2max reading
                // is surfaced but does not force the sample window to be re-sent. Rejected samples
                // are quarantined by key and the cursor moves past them.
                activity.markSamplesSynced(at: now, rejectedKeys: rejected)
            }
        } else {
            activity.markSamplesSynced(at: now, rejectedKeys: [])
        }

        return report
    }
}
