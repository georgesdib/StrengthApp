import XCTest

@testable import StrengthApp
import StrengthCore

@MainActor
final class HealthKitActivitySyncTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "com.georgesdibpersonalteam.StrengthApp.activity.(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func session() -> IOSSession {
        IOSSession(
            baseURL: URL(string: "http://127.0.0.1:8000")!,
            token: "token",
            deviceID: "device-1"
        )
    }

    private func workout(
        key: String = "00112233445566778899aabbccddeeff",
        start: Date,
        end: Date
    ) -> HealthKitActivityWorkout {
        HealthKitActivityWorkout(
            key: key,
            activityType: "HKWorkoutActivityTypeTraditionalStrengthTraining",
            startedAt: HealthKitActivityFormat.iso(start),
            endedAt: HealthKitActivityFormat.iso(end),
            durationS: max(Int(end.timeIntervalSince(start)), 1),
            sourceName: "Apple Watch"
        )
    }

    private func sample(
        key: String = "ffeeddccbbaa99887766554433221100",
        workoutKey: String,
        at date: Date
    ) -> HealthKitActivitySample {
        HealthKitActivitySample(
            key: key,
            workoutKey: workoutKey,
            kind: "heart_rate",
            sampledAt: HealthKitActivityFormat.iso(date),
            value: 120,
            unit: "count/min",
            association: "workout",
            sourceName: "Apple Watch"
        )
    }

    private final class StubActivity: HealthKitActivityProviding {
        let batch: HealthKitActivityBatch
        var isAvailable = true
        var lastSyncedAt: Date
        var lastWorkoutAt: Date
        private(set) var authorizationRequests = 0
        private(set) var workoutCommits: [[HealthKitActivityWorkout]] = []
        private(set) var sampleCommits: [Date] = []

        init(batch: HealthKitActivityBatch, now: Date) {
            self.batch = batch
            self.lastSyncedAt = now
            self.lastWorkoutAt = now
        }

        func requestAuthorization() async throws {
            authorizationRequests += 1
        }

        func fetchBatch(now: Date) async throws -> HealthKitActivityBatch { batch }

        func markWorkoutsSynced(_ workouts: [HealthKitActivityWorkout]) {
            workoutCommits.append(workouts)
        }

        func markSamplesSynced(at date: Date) {
            sampleCommits.append(date)
        }
    }

    private func makeClient(
        workoutsResponse: String = #"{"workouts":1,"created":1,"existing":0,"rejected":0}"#,
        samplesResponse: String = #"{"samples":1,"created":1,"existing":0,"rejected":0}"#
    ) -> (IOSAPIClient, StubTransport) {
        let transport = StubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/healthkit/workouts":
                return (200, Data(workoutsResponse.utf8))
            case "/api/ios/v1/healthkit/samples":
                return (200, Data(samplesResponse.utf8))
            default:
                return (404, Data())
            }
        }
        return (IOSAPIClient(transport: transport), transport)
    }

    // MARK: - Orchestration

    func testCompleteSyncAdvancesBothCursors() async throws {
        let now = Date()
        let start = now.addingTimeInterval(-3600)
        let workout = workout(start: start, end: now)
        let sample = sample(workoutKey: workout.key, at: now.addingTimeInterval(-1800))
        let activity = StubActivity(
            batch: HealthKitActivityBatch(workouts: [workout], samples: [sample]),
            now: now
        )
        let (client, transport) = makeClient()

        let report = try await HealthKitActivitySync(client: client, activity: activity)
            .run(session: session(), at: now)

        XCTAssertFalse(report.isPartial)
        XCTAssertEqual(report.workoutsCreated, 1)
        XCTAssertEqual(report.samplesCreated, 1)
        XCTAssertEqual(activity.workoutCommits.count, 1)
        XCTAssertEqual(activity.sampleCommits, [now])
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testRejectedWorkoutHoldsWorkoutCursorAndDefersSamples() async throws {
        let now = Date()
        let workout = workout(start: now.addingTimeInterval(-3600), end: now)
        let sample = sample(workoutKey: workout.key, at: now.addingTimeInterval(-1800))
        let activity = StubActivity(
            batch: HealthKitActivityBatch(workouts: [workout], samples: [sample]),
            now: now
        )
        let (client, transport) = makeClient(
            workoutsResponse: #"{"workouts":1,"created":0,"existing":0,"rejected":1}"#
        )

        let report = try await HealthKitActivitySync(client: client, activity: activity)
            .run(session: session(), at: now)

        XCTAssertTrue(report.isPartial)
        XCTAssertTrue(report.samplesDeferred)
        XCTAssertEqual(report.workoutsRejected, 1)
        XCTAssertTrue(activity.workoutCommits.isEmpty)
        XCTAssertTrue(activity.sampleCommits.isEmpty)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.url?.path, "/api/ios/v1/healthkit/workouts")
    }

    func testRejectedSampleHoldsOnlyTheSampleCursor() async throws {
        let now = Date()
        let workout = workout(start: now.addingTimeInterval(-3600), end: now)
        let sample = sample(workoutKey: workout.key, at: now.addingTimeInterval(-1800))
        let activity = StubActivity(
            batch: HealthKitActivityBatch(workouts: [workout], samples: [sample]),
            now: now
        )
        let (client, _) = makeClient(
            samplesResponse: #"{"samples":1,"created":0,"existing":0,"rejected":1}"#
        )

        let report = try await HealthKitActivitySync(client: client, activity: activity)
            .run(session: session(), at: now)

        XCTAssertTrue(report.isPartial)
        XCTAssertEqual(activity.workoutCommits.count, 1)
        XCTAssertTrue(activity.sampleCommits.isEmpty)
        XCTAssertEqual(report.samplesRejected, 1)
    }

    func testSkippedMetricIsSurfacedWithoutHoldingTheSampleCursor() async throws {
        let now = Date()
        let workout = workout(start: now.addingTimeInterval(-3600), end: now)
        let metric = HealthKitActivityMetric(
            key: "11112222333344445555666677778888",
            kind: "vo2max",
            measuredAt: HealthKitActivityFormat.iso(now),
            value: 48,
            method: "Apple Watch"
        )
        let activity = StubActivity(
            batch: HealthKitActivityBatch(workouts: [workout], samples: [], metrics: [metric]),
            now: now
        )
        let (client, _) = makeClient(
            samplesResponse: #"{"samples":0,"created":0,"existing":0,"rejected":0,"metrics":{"written":0,"skipped":1}}"#
        )

        let report = try await HealthKitActivitySync(client: client, activity: activity)
            .run(session: session(), at: now)

        XCTAssertTrue(report.isPartial)
        XCTAssertEqual(report.metricsSkipped, 1)
        XCTAssertEqual(activity.workoutCommits.count, 1)
        XCTAssertEqual(activity.sampleCommits, [now])
    }

    // MARK: - Cursor and interval persistence

    func testWorkoutAndSampleCursorsAdvanceIndependently() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = HealthKitActivityService(defaults: defaults)
        let now = Date()
        let start = now.addingTimeInterval(-1800)
        let workout = workout(start: start, end: now)

        service.markWorkoutsSynced([workout])

        // The workout cursor is parsed back from the ISO string the upload carried, so compare
        // with the one-second precision that format keeps.
        XCTAssertEqual(
            service.lastWorkoutAt.timeIntervalSince1970,
            now.timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(service.lastSyncedAt, HealthKitActivityService.defaultCutoff)
        XCTAssertEqual(service.knownIntervals(now: now).map(\.key), [workout.key])
        XCTAssertEqual(
            service.knownIntervals(now: now).first?.tailEnd.timeIntervalSince1970 ?? 0,
            now.addingTimeInterval(600).timeIntervalSince1970,
            accuracy: 1
        )

        let sampleSync = now.addingTimeInterval(120)
        service.markSamplesSynced(at: sampleSync)

        XCTAssertEqual(service.lastSyncedAt, sampleSync)
        XCTAssertEqual(
            service.lastWorkoutAt.timeIntervalSince1970,
            now.timeIntervalSince1970,
            accuracy: 1
        )
    }

    func testPersistedIntervalAssociatesASampleOutsideThisRunsWorkoutQuery() {
        let now = Date()
        let workoutEnd = now.addingTimeInterval(-30 * 60 * 60)
        let interval = HealthKitActivityInterval(
            key: "stored-workout",
            start: workoutEnd.addingTimeInterval(-3600),
            workoutEnd: workoutEnd,
            tailEnd: workoutEnd.addingTimeInterval(600)
        )

        let lateSample = HealthKitActivityService.interval(
            containing: workoutEnd.addingTimeInterval(300),
            in: [interval]
        )
        XCTAssertEqual(lateSample?.key, "stored-workout")
        XCTAssertEqual(
            HealthKitActivityService.interval(
                containing: workoutEnd.addingTimeInterval(601),
                in: [interval]
            ),
            nil
        )
    }

    func testIntervalsMergeByKeyAndAgeOut() {
        let now = Date()
        let recent = HealthKitActivityInterval(
            key: "a",
            start: now.addingTimeInterval(-3600),
            workoutEnd: now,
            tailEnd: now.addingTimeInterval(600)
        )
        let duplicate = HealthKitActivityInterval(
            key: "a",
            start: now.addingTimeInterval(-7200),
            workoutEnd: now.addingTimeInterval(-3600),
            tailEnd: now.addingTimeInterval(-3000)
        )
        let stale = HealthKitActivityInterval(
            key: "b",
            start: now.addingTimeInterval(-30 * 24 * 3600),
            workoutEnd: now.addingTimeInterval(-30 * 24 * 3600 + 3600),
            tailEnd: now.addingTimeInterval(-30 * 24 * 3600 + 4200)
        )

        let merged = HealthKitActivityService.mergedIntervals(
            [duplicate, recent, stale], now: now, retention: 14 * 24 * 3600
        )

        XCTAssertEqual(merged.map(\.key), ["a"])
        XCTAssertEqual(merged.first?.workoutEnd, now)
    }

    // MARK: - Response contract

    func testUploadResultDecodesRejectedAndNestedMetricSkips() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try decoder.decode(
            HealthKitActivityUploadResult.self,
            from: Data(#"""
            {"samples":3,"created":1,"existing":1,"rejected":1,
             "metrics":{"written":2,"skipped":1}}
            """#.utf8)
        )

        XCTAssertEqual(result.created, 1)
        XCTAssertEqual(result.existing, 1)
        XCTAssertEqual(result.rejected, 1)
        XCTAssertEqual(result.metrics?.written, 2)
        XCTAssertEqual(result.skippedMetrics, 1)
        XCTAssertTrue(result.isPartial)
    }

    func testMetricsOnlyResponseDefaultsMissingRejectedToZero() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try decoder.decode(
            HealthKitActivityUploadResult.self,
            from: Data(#"{"samples":0,"created":0,"existing":0,"metrics":{"written":1,"skipped":0}}"#.utf8)
        )

        XCTAssertEqual(result.rejected, 0)
        XCTAssertFalse(result.isPartial)
    }
}
