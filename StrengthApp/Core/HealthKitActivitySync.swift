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
    /// True when a rejected workout stopped samples from being submitted in this run.
    var samplesDeferred = false

    var isEmpty: Bool { !hadActivity }

    var isPartial: Bool {
        workoutsRejected > 0 || samplesRejected > 0 || metricsSkipped > 0 || samplesDeferred
    }
}

/// Orchestrates one incremental HealthKit activity sync.
///
/// Cursors are advanced per half, and only after that half was completely accepted:
/// - a workout rejection holds the workout cursor and defers samples to the next run;
/// - a sample rejection holds the sample cursor;
/// - a transport failure advances neither cursor.
@MainActor
struct HealthKitActivitySync {
    private let client: IOSAPIClient
    private let activity: any HealthKitActivityProviding

    init(client: IOSAPIClient, activity: any HealthKitActivityProviding) {
        self.client = client
        self.activity = activity
    }

    func run(session: IOSSession, at now: Date = Date()) async throws -> HealthKitActivitySyncReport {
        let batch = try await activity.fetchBatch(now: now)
        var report = HealthKitActivitySyncReport()
        report.hadActivity = !batch.isEmpty

        if !batch.workouts.isEmpty {
            let result = try await client.uploadActivity(
                HealthKitActivityWorkoutsBody(workouts: batch.workouts),
                session: session,
                idempotencyKey: UUID().uuidString
            )
            report.workoutsCreated = result.created
            report.workoutsExisting = result.existing
            report.workoutsRejected = result.rejected
            guard result.rejected == 0 else {
                // The response carries counts, not keys, so the client cannot know which workout
                // was rejected. Sending samples now could reference a workout the server does not
                // have, so the whole sample half waits while the workout cursor stays put.
                report.samplesDeferred = !batch.samples.isEmpty || !batch.metrics.isEmpty
                return report
            }
            activity.markWorkoutsSynced(batch.workouts)
        }

        if !batch.samples.isEmpty || !batch.metrics.isEmpty {
            let result = try await client.uploadActivity(
                HealthKitActivitySamplesBody(samples: batch.samples, metrics: batch.metrics),
                session: session,
                idempotencyKey: UUID().uuidString
            )
            report.samplesCreated = result.created
            report.samplesExisting = result.existing
            report.samplesRejected = result.rejected
            report.metricsWritten = result.metrics?.written ?? 0
            report.metricsSkipped = result.skippedMetrics
            // Metrics have no cursor and are re-read on every sync, so a skipped VO2max reading is
            // surfaced but does not force the whole sample window to be re-sent forever. A rejected
            // heart-rate sample does hold the cursor: its identity conflict needs investigation.
            if result.rejected == 0 {
                activity.markSamplesSynced(at: now)
            }
        } else {
            activity.markSamplesSynced(at: now)
        }

        return report
    }
}
