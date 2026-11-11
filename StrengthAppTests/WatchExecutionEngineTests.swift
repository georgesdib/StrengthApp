import XCTest

@testable import StrengthApp
import StrengthCore

/// Phase 6.3b: the execution engine's lifecycle, persistence and flush rules against a stub
/// server. No watch target, HealthKit or SwiftUI is involved.
@MainActor
final class WatchExecutionEngineTests: XCTestCase {
    private var fileURL: URL!
    private var clock: Date!
    private var store: OfflineCaptureStore!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-engine-\(UUID().uuidString).json")
        clock = Date(timeIntervalSince1970: 1_800_000_000)
        store = OfflineCaptureStore(fileURL: fileURL, now: { [unowned self] in self.clock })
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    // MARK: - Start

    func testStartPersistsTheSessionAndDerivesTheClockOffsetFromStartedAt() async throws {
        // Server started_at is one hour behind the (fast) watch clock.
        clock = try XCTUnwrap(ServerClock.parse("2026-11-07T16:00:00+00:00"))
            .addingTimeInterval(3_600)
        let transport = AsyncStubTransport { _ in
            (200, Data(Fixtures.workoutInProgress.utf8))
        }
        let engine = makeEngine(transport: transport)

        let started = await engine.start(issuedPlanID: "plan-1", session: session())

        XCTAssertTrue(started)
        XCTAssertEqual(engine.phase, .active)
        XCTAssertEqual(engine.workout?.workoutId, "workout-1")
        let record = try XCTUnwrap(engine.sessionRecord)
        XCTAssertEqual(record.clockOffsetSeconds ?? 0, -3_600, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(store.load().session).sessionUUID, record.sessionUUID)
    }

    func testStartFailureStaysReadyAndKeepsTheError() async {
        let transport = AsyncStubTransport { _ in (500, Data()) }
        let engine = makeEngine(transport: transport)

        let started = await engine.start(issuedPlanID: "plan-1", session: session())

        XCTAssertFalse(started)
        XCTAssertEqual(engine.phase, .ready)
        XCTAssertNotNil(engine.lastError)
        XCTAssertNil(try? store.load().session)
    }

    // MARK: - Sets

    func testFailedSetIsPersistedWithItsOriginalTimestampAndStaysQueued() async throws {
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/workouts") == true {
                return (200, Data(Fixtures.workoutInProgress.utf8))
            }
            throw APIError.transport("offline")
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())

        let stop = await engine.logSet(entry(setIndex: 1), session: session())

        XCTAssertTrue(stop.isRetryable)
        XCTAssertEqual(engine.pendingCount, 1)
        let capture = try store.load()
        let operation = try XCTUnwrap(capture.operations.first)
        XCTAssertEqual(operation.state, .pending)
        XCTAssertNotNil(operation.attemptedAt)
        guard case .addSet(let body) = operation.body else {
            return XCTFail("expected an add-set operation")
        }
        XCTAssertEqual(body.setIndex, 1)
        XCTAssertNotNil(body.performedAt)
    }

    func testAcknowledgedSetIsRemovedAndTheSnapshotAdvances() async throws {
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/sets") == true {
                return (200, Data(Fixtures.workoutWithSet.utf8))
            }
            return (200, Data(Fixtures.workoutInProgress.utf8))
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())

        let stop = await engine.logSet(entry(setIndex: 1), session: session())

        XCTAssertEqual(stop, .allSent)
        XCTAssertEqual(engine.pendingCount, 0)
        XCTAssertEqual(engine.completedSetCount, 1)
        XCTAssertEqual(engine.workout?.sets?.count, 1)
        let remaining = try store.load().operations
        XCTAssertTrue(remaining.isEmpty)
    }

    func testAnUnauthorizedFlushKeepsTheQueueAndReportsCredentialsMissing() async throws {
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/workouts") == true {
                return (200, Data(Fixtures.workoutInProgress.utf8))
            }
            return (401, Data(#"{"error":"expired"}"#.utf8))
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())

        let stop = await engine.logSet(entry(setIndex: 1), session: session())

        XCTAssertEqual(stop, .credentialsMissing)
        XCTAssertEqual(engine.pendingCount, 1)
        let operation = try XCTUnwrap(try store.load().operations.first)
        XCTAssertEqual(operation.state, .pending)
    }

    func testUndoOnlyCancelsASetThatWasNeverAttempted() async throws {
        _ = try store.setActiveWorkout(try decode(Fixtures.workoutInProgress))
        _ = try store.setSession(WatchSessionRecord(
            sessionUUID: "session-1",
            startedAt: clock,
            clockOffsetSeconds: 0
        ))
        let sent = OfflineOperation(
            operationId: "op-sent",
            workoutId: "workout-1",
            body: .addSet(addSetBody(setIndex: 1)),
            createdAt: clock,
            localSetId: -1,
            attemptedAt: clock
        )
        let unsent = OfflineOperation(
            operationId: "op-unsent",
            workoutId: "workout-1",
            body: .addSet(addSetBody(setIndex: 2)),
            createdAt: clock,
            localSetId: -2
        )
        _ = try store.record(sent)
        _ = try store.record(unsent)

        let engine = makeEngine(transport: AsyncStubTransport { _ in (200, Data()) })
        try engine.restore()

        XCTAssertEqual(engine.pendingCount, 2)
        XCTAssertTrue(engine.canUndoLastSet)
        XCTAssertTrue(engine.undoLastPendingSet(), "the newest set was never sent")
        XCTAssertEqual(engine.pendingCount, 1)
        // The attempted set may already have reached the server, so it is not cancellable.
        XCTAssertFalse(engine.canUndoLastSet)
        XCTAssertFalse(engine.undoLastPendingSet())
        XCTAssertEqual(engine.pendingCount, 1)
    }

    // MARK: - Finish and discard

    func testFinishPersistsTheIntentBeforeTheServerCallAndQueuesIt() async throws {
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/workouts") == true {
                return (200, Data(Fixtures.workoutInProgress.utf8))
            }
            throw APIError.transport("offline")
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())
        let endedAt = try XCTUnwrap(engine.sessionRecord?.startedAt)

        let stop = await engine.finish(sessionRpe: 8, session: session())

        XCTAssertTrue(stop.isRetryable)
        XCTAssertEqual(engine.phase, .finishing)
        let record = try XCTUnwrap(try store.load().session)
        let finish = try XCTUnwrap(record.finish)
        XCTAssertFalse(finish.serverAcked)
        XCTAssertEqual(finish.sessionRpe, 8)
        let expectedEnd = clock.addingTimeInterval(record.clockOffsetSeconds ?? 0)
        XCTAssertEqual(finish.endedAt.timeIntervalSince(expectedEnd), 0, accuracy: 1)
        XCTAssertGreaterThan(finish.endedAt, endedAt.addingTimeInterval(-1))
        XCTAssertEqual(engine.pendingCount, 1)
    }

    func testDiscardClearsTheLocalRecord() async throws {
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/abandon") == true {
                return (200, Data(Fixtures.workoutCompleted.utf8))
            }
            return (200, Data(Fixtures.workoutInProgress.utf8))
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())

        await engine.discard(session: session())

        XCTAssertEqual(engine.phase, .abandoned)
        XCTAssertNil(engine.workout)
        let capture = try store.load()
        XCTAssertNil(capture.session)
        XCTAssertNil(capture.activeWorkout)
    }

    // MARK: - Relaunch

    func testRelaunchRestoresAnActiveSessionAndItsQueue() async throws {
        _ = try store.setActiveWorkout(try decode(Fixtures.workoutInProgress))
        _ = try store.setSession(WatchSessionRecord(
            sessionUUID: "session-1",
            startedAt: clock,
            planRevision: 0,
            clockOffsetSeconds: 0
        ))
        _ = try store.record(OfflineOperation(
            operationId: "op-1",
            workoutId: "workout-1",
            body: .addSet(addSetBody(setIndex: 1)),
            createdAt: clock,
            localSetId: -1
        ))

        let engine = makeEngine(transport: AsyncStubTransport { _ in (200, Data()) })
        try engine.restore()

        XCTAssertEqual(engine.phase, .active)
        XCTAssertEqual(engine.pendingCount, 1)
        XCTAssertEqual(engine.workout?.workoutId, "workout-1")
    }

    // MARK: - Helpers

    private func makeEngine(transport: HTTPTransport) -> WatchExecutionEngine {
        WatchExecutionEngine(
            client: IOSAPIClient(transport: transport),
            store: store,
            now: { [unowned self] in self.clock }
        )
    }

    private func session() -> IOSSession {
        IOSSession(baseURL: URL(string: "http://home.local:8000")!, token: "token", deviceID: "watch-1")
    }

    private func entry(setIndex: Int) -> WatchExecutionEngine.SetEntry {
        WatchExecutionEngine.SetEntry(
            exerciseId: "competition_squat",
            planItemIndex: 0,
            setIndex: setIndex,
            loadKg: 140,
            reps: 3,
            rir: 2
        )
    }

    private func addSetBody(setIndex: Int) -> AddSetRequest {
        AddSetRequest(
            exerciseId: "competition_squat",
            loadKg: 140,
            reps: 3,
            rir: 2,
            velocityMps: nil,
            setIndex: setIndex,
            planItemIndex: 0,
            performedAt: "2026-11-07T16:05:00.000Z"
        )
    }

    private func decode(_ json: String) throws -> WorkoutDetail {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(WorkoutDetail.self, from: Data(json.utf8))
    }
}
