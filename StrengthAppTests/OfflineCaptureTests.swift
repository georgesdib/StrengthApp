import XCTest

@testable import StrengthApp
import StrengthCore

final class OfflineCaptureTests: XCTestCase {
    private var fileURL: URL!
    private var clock: Date!
    private var store: OfflineCaptureStore!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-capture-\(UUID().uuidString).json")
        clock = Date(timeIntervalSince1970: 1_800_000_000)
        store = OfflineCaptureStore(fileURL: fileURL, now: { [unowned self] in self.clock })
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func workout() -> WorkoutDetail {
        WorkoutDetail(
            workoutId: "workout-1",
            prescriptionId: "rx-1",
            forDate: "2026-11-08",
            sessionType: "squat",
            status: "in_progress",
            plan: PrescriptionPlan(
                forDate: "2026-11-08",
                sessionType: "squat",
                sessionLabel: "Squat",
                items: [
                    PrescriptionItem(
                        orderIndex: 1,
                        exerciseId: "competition_squat",
                        sets: 3,
                        repsLow: 5,
                        repsHigh: 5,
                        loadKg: 140,
                        loadBasis: "external",
                        rirTarget: 2,
                        effortModel: "rir",
                        refs: nil,
                        restS: 180,
                        essential: true
                    )
                ],
                warnings: nil,
                issues: nil
            ),
            sets: [
                WorkoutSet(
                    setId: 1,
                    exerciseId: "competition_squat",
                    setIndex: 1,
                    planItemIndex: 1,
                    loadKg: 140,
                    reps: 3,
                    rir: 2,
                    velocity: 0.62,
                    source: "manual",
                    repsDetail: nil,
                    repSummary: nil
                )
            ],
            forms: [WorkoutForm(formId: 1, workoutId: "workout-1", exerciseId: "competition_squat", rating: 4, note: nil)],
            elapsedSeconds: 120,
            sessionRpe: nil,
            startedAt: "2026-11-08T10:00:00Z"
        )
    }

    private func addOperation(localSetId: Int = -1, id: String = "op-add") -> OfflineOperation {
        OfflineOperation(
            operationId: id,
            workoutId: "workout-1",
            body: .addSet(
                AddSetRequest(
                    exerciseId: "competition_squat",
                    loadKg: 140,
                    reps: 3,
                    rir: 2,
                    velocityMps: 0.62,
                    setIndex: 2,
                    planItemIndex: 1,
                    repVelocities: [RepVelocity(repIndex: 1, velocityMps: 0.62)],
                    performedAt: "2026-11-08T10:02:00Z"
                )
            ),
            createdAt: clock,
            localSetId: localSetId
        )
    }

    func testActiveWorkoutAndOrderedOperationsRoundTrip() throws {
        _ = try store.setActiveWorkout(workout())
        let form = OfflineOperation(
            operationId: "op-form",
            workoutId: "workout-1",
            body: .rateForm(FormRatingRequest(exerciseId: "competition_squat", rating: 4, note: nil)),
            createdAt: clock.addingTimeInterval(1)
        )
        let finish = OfflineOperation(
            operationId: "op-finish",
            workoutId: "workout-1",
            body: .completeWorkout(
                CompleteWorkoutRequest(
                    sessionRpe: 7,
                    notRecorded: false,
                    durationMin: 42,
                    notes: "offline finish",
                    endedAt: "2026-11-08T10:42:00Z"
                )
            ),
            createdAt: clock.addingTimeInterval(2)
        )
        _ = try store.record(addOperation())
        _ = try store.record(form)
        _ = try store.record(finish)

        let loaded = try store.load()
        XCTAssertEqual(loaded.activeWorkout?.workoutId, "workout-1")
        XCTAssertEqual(loaded.activeWorkout?.plan?.items.first?.exerciseId, "competition_squat")
        XCTAssertEqual(loaded.activeWorkout?.sets?.first?.planItemIndex, 1)
        XCTAssertEqual(loaded.operations.map(\.operationId), ["op-add", "op-form", "op-finish"])
        XCTAssertEqual(loaded.operations[0].localSetId, -1)
        guard case .addSet(let body) = loaded.operations[0].body else {
            return XCTFail("expected add-set body")
        }
        XCTAssertEqual(body.performedAt, "2026-11-08T10:02:00Z")
        guard case .completeWorkout(let finishBody) = loaded.operations[2].body else {
            return XCTFail("expected finish body")
        }
        XCTAssertEqual(finishBody.endedAt, "2026-11-08T10:42:00Z")
    }

    func testCannotSwitchActiveWorkoutWithQueuedOperations() throws {
        _ = try store.setActiveWorkout(workout())
        _ = try store.record(addOperation(id: "op-queued"))
        let other = WorkoutDetail(
            workoutId: "workout-2",
            prescriptionId: nil,
            forDate: "2026-11-09",
            sessionType: "bench",
            status: "in_progress",
            plan: nil,
            sets: [],
            forms: [],
            elapsedSeconds: 0,
            sessionRpe: nil,
            startedAt: "2026-11-09T10:00:00Z"
        )
        XCTAssertThrowsError(try store.setActiveWorkout(other)) { error in
            guard case OfflineCaptureStoreError.invalidOperation = error else {
                return XCTFail("expected active-workout switch rejection")
            }
        }
    }

    func testCancellationIsOnlyAllowedBeforeTheFirstSend() throws {
        _ = try store.setActiveWorkout(workout())
        _ = try store.record(addOperation(id: "op-cancel"))
        _ = try store.cancel("op-cancel")
        XCTAssertTrue(try store.load().operations.isEmpty)

        _ = try store.record(addOperation(id: "op-sent"))
        _ = try store.markAttempted("op-sent")
        XCTAssertThrowsError(try store.cancel("op-sent")) { error in
            guard case OfflineCaptureStoreError.invalidOperation = error else {
                return XCTFail("expected invalid operation, got \(error)")
            }
        }
    }

    func testLocalSetIDsAreNegativeAndUnique() throws {
        _ = try store.setActiveWorkout(workout())
        XCTAssertEqual(try store.nextLocalSetId(), -1)
        _ = try store.record(addOperation(localSetId: -1, id: "op-1"))
        XCTAssertEqual(try store.nextLocalSetId(), -2)
        XCTAssertThrowsError(try store.record(addOperation(localSetId: -1, id: "op-2"))) { error in
            guard case OfflineCaptureStoreError.invalidOperation = error else {
                return XCTFail("expected duplicate local id rejection")
            }
        }
    }

    func testQueueCapAndRetention() throws {
        _ = try store.setActiveWorkout(workout())
        for index in 0..<OfflineCaptureStore.maxOperations {
            _ = try store.record(addOperation(localSetId: -(index + 1), id: "op-\(index)"))
        }
        XCTAssertThrowsError(
            try store.record(addOperation(localSetId: -999, id: "op-overflow"))
        ) { error in
            XCTAssertEqual(error as? OfflineCaptureStoreError, .full)
        }

        let old = OfflineOperation(
            operationId: "op-old",
            workoutId: "workout-1",
            body: .rateForm(FormRatingRequest(exerciseId: "competition_squat", rating: 4, note: nil)),
            createdAt: clock
        )
        let cleanupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-capture-old-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cleanupURL) }
        var now = clock!
        let cleanupStore = OfflineCaptureStore(fileURL: cleanupURL, now: { now })
        _ = try cleanupStore.setActiveWorkout(workout())
        _ = try cleanupStore.record(old)
        now = clock.addingTimeInterval(OfflineCaptureStore.retention + 1)
        let retained = try cleanupStore.load().operations
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained.first?.state, .expired)
        XCTAssertTrue(try cleanupStore.replayable(now: now).isEmpty)
        XCTAssertNotNil(retained.first?.lastError)
    }

    func testUnsupportedVersionIsRejected() throws {
        let unsupported = OfflineCapture(version: 99, updatedAt: clock)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(unsupported).write(to: fileURL)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? OfflineCaptureStoreError, .unsupportedVersion(99))
        }
    }

    func testReplayWindowAndStates() throws {
        _ = try store.setActiveWorkout(workout())
        var old = addOperation(id: "op-replay")
        old = OfflineOperation(
            operationId: old.operationId,
            workoutId: old.workoutId,
            body: old.body,
            createdAt: clock.addingTimeInterval(-(OfflineCaptureStore.replayWindow + 1)),
            localSetId: old.localSetId
        )
        _ = try store.record(old)
        XCTAssertTrue(try store.replayable(now: clock).isEmpty)

        _ = try store.updateState(operationId: "op-replay", state: .conflict, error: "ended elsewhere")
        let operation = try store.load().operations.first
        XCTAssertEqual(operation?.state, .conflict)
        XCTAssertEqual(operation?.lastError, "ended elsewhere")
    }
}
