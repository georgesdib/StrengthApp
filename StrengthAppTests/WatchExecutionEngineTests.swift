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
        clock = ServerClock.parse("2026-11-07T16:00:00+00:00")!
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
            (200, Data(Self.watchWorkout.utf8))
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
                return (200, Data(Self.watchWorkout.utf8))
            }
            throw APIError.transport("offline")
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())

        let result = await engine.logSet(entry(setIndex: 1), session: session())

        XCTAssertTrue(result.persisted, "stop=\(result.stop) error=\(engine.lastError ?? "nil")")
        XCTAssertTrue(result.stop.isRetryable, "stop=\(result.stop)")
        XCTAssertEqual(engine.pendingCount, 1, "stop=\(result.stop)")
        let capture = try store.load()
        let operation = try XCTUnwrap(capture.operations.first { $0.kind == .addSet })
        XCTAssertEqual(operation.state, .pending)
        // The start event is queued ahead of the set, so the first failing send is that batch.
        XCTAssertEqual(capture.operations.map(\.kind), [.executionEvents, .addSet, .executionEvents])
        XCTAssertNotNil(capture.operations.first?.attemptedAt)
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
            if request.url?.path.hasSuffix("/execution-events") == true {
                return (200, Data(Self.eventsAccepted.utf8))
            }
            return (200, Data(Self.watchWorkout.utf8))
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())

        let result = await engine.logSet(entry(setIndex: 1), session: session())

        XCTAssertTrue(result.persisted)
        XCTAssertEqual(result.stop, .allSent)
        XCTAssertEqual(engine.pendingCount, 0)
        XCTAssertEqual(engine.completedSetCount, 1)
        XCTAssertEqual(engine.workout?.sets?.count, 1)
        let remaining = try store.load().operations
        XCTAssertTrue(remaining.isEmpty)
    }

    func testAnUnauthorizedFlushKeepsTheQueueAndReportsCredentialsMissing() async throws {
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/workouts") == true {
                return (200, Data(Self.watchWorkout.utf8))
            }
            return (401, Data(#"{"error":"expired"}"#.utf8))
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())

        let result = await engine.logSet(entry(setIndex: 1), session: session())

        XCTAssertEqual(result.stop, .credentialsMissing)
        XCTAssertEqual(engine.pendingCount, 1)
        let operation = try XCTUnwrap(try store.load().operations.first)
        XCTAssertEqual(operation.state, .pending)
    }

    func testUndoOnlyCancelsASetThatWasNeverAttempted() async throws {
        _ = try store.setActiveWorkout(try decode(Self.watchWorkout))
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

    // MARK: - Telemetry

    func testBeginSetRecordsAnExplicitStartAndMarksTheActiveSet() async throws {
        let transport = AsyncStubTransport { request in
            (200, Data(Self.watchWorkout.utf8))
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())
        try engine.selectItem(0)

        try engine.beginSet()

        let active = try XCTUnwrap(engine.activeSet)
        XCTAssertEqual(active.planItemIndex, 0)
        XCTAssertEqual(active.setIndex, 1)
        XCTAssertEqual(engine.pendingCount, 0, "a start event is not user-facing pending work")
        XCTAssertEqual(engine.pendingEventCount, 1)

        let capture = try store.load()
        guard case .executionEvents(let events) = try XCTUnwrap(capture.operations.first).body else {
            return XCTFail("expected a queued event batch")
        }
        XCTAssertEqual(events.map(\.eventType), [.exerciseStarted, .setStarted])
        XCTAssertEqual(events.compactMap(\.localSetId), [active.localSetID])
    }

    func testLoggingASetClosesAnOpenRestWithOneDeliberateEvent() async throws {
        // The set fails, so the queue keeps its order and nothing is acknowledged away.
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/sets") == true {
                throw APIError.transport("offline")
            }
            return (200, Data(Self.watchWorkout.utf8))
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())
        try engine.startRest(seconds: 120, planItemIndex: 0)

        _ = await engine.logSet(entry(setIndex: 1), session: session())

        let capture = try store.load()
        let types = capture.operations.flatMap { operation -> [ExecutionEventType] in
            guard case .executionEvents(let events) = operation.body else { return [] }
            return events.map(\.eventType)
        }
        XCTAssertEqual(types, [.restStarted, .restCompleted, .exerciseStarted, .setCompleted])
        XCTAssertFalse(types.contains(.restSkipped))
        XCTAssertNotNil(capture.session?.rest?.endedAt, "the rest is closed, not left open")
    }

    func testSetCompletionCarriesTheAcknowledgedServerSetId() async throws {
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/sets") == true {
                return (200, Data(Fixtures.workoutWithSet.utf8))
            }
            if request.url?.path.hasSuffix("/execution-events") == true {
                return (200, Data(Self.eventsAccepted.utf8))
            }
            return (200, Data(Self.watchWorkout.utf8))
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())
        try engine.selectItem(0)
        try engine.beginSet()
        let token = try XCTUnwrap(engine.activeSet?.localSetID)

        _ = await engine.logSet(entry(setIndex: 1), session: session())

        let eventsRequest = try XCTUnwrap(
            transport.requests.last { $0.url?.path.hasSuffix("/execution-events") == true }
        )
        let body = try XCTUnwrap(eventsRequest.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        let completed = try XCTUnwrap(events.first { ($0["event_type"] as? String) == "set_completed" })
        XCTAssertEqual(completed["set_id"] as? Int, 1)
        XCTAssertEqual(completed["local_set_id"] as? String, token)
    }

    func testExtendingARestRecordsTheAddedSeconds() async throws {
        let transport = AsyncStubTransport { request in
            (200, Data(Self.watchWorkout.utf8))
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())
        try engine.startRest(seconds: 120, planItemIndex: 0)

        try engine.extendRest(by: 15)

        let capture = try store.load()
        let rest = try XCTUnwrap(capture.session?.rest)
        XCTAssertEqual(rest.addedSeconds, 15)
        let batches = capture.operations.compactMap { operation -> [ExecutionEvent]? in
            guard case .executionEvents(let events) = operation.body else { return nil }
            return events
        }
        let extended = try XCTUnwrap(batches.last?.last)
        XCTAssertEqual(extended.eventType, .restExtended)
        guard case .number(let added)? = extended.payload?["added_s"] else {
            return XCTFail("expected added_s in the payload")
        }
        XCTAssertEqual(added, 15)
    }

    // MARK: - HealthKit finalisation state

    func testHealthKitOutcomeAndDismissalPersist() async throws {
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/workouts") == true {
                return (200, Data(Self.watchWorkout.utf8))
            }
            throw APIError.transport("offline")
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())
        _ = await engine.finish(sessionRpe: 8, session: session())

        let input = try XCTUnwrap(engine.healthKitInput())
        XCTAssertEqual(input.state, .pending)
        XCTAssertEqual(input.attempts, 0)
        XCTAssertEqual(input.effort, 8)
        XCTAssertEqual(input.endedAt, try XCTUnwrap(engine.sessionRecord?.finish?.endedAt))

        engine.applyHealthKitOutcome(HealthKitFinalizationOutcome(
            state: .unsaved, attempts: 3, failure: "authorisation denied"
        ))

        XCTAssertEqual(engine.healthKitInput()?.state, .unsaved)
        XCTAssertEqual(engine.healthKitFailure, "authorisation denied")
        let stored = try XCTUnwrap(try store.load().session?.finish)
        XCTAssertEqual(stored.hkState, .unsaved)
        XCTAssertEqual(stored.hkAttempts, 3)

        engine.dismissHealthKitNotice()

        let relaunched = makeEngine(transport: AsyncStubTransport { _ in (200, Data()) })
        try relaunched.restore()
        XCTAssertEqual(relaunched.healthKitInput()?.dismissed, true)
    }

    // MARK: - Phase 6.4 corrective fixes

    func testAnActiveExerciseCannotBeLeftUntilItIsEnded() async throws {
        let transport = AsyncStubTransport { _ in (200, Data(Self.twoItemWorkout.utf8)) }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())
        try engine.selectItem(0)
        try engine.beginSet(loadKg: 140, reps: 5)

        XCTAssertFalse(engine.canLeaveExercise)
        try engine.clearSelection()
        XCTAssertEqual(engine.selectedItem?.orderIndex, 0, "the list stays out of reach")
        try engine.selectItem(1)
        XCTAssertEqual(engine.selectedItem?.orderIndex, 0, "another exercise cannot be opened")
    }

    func testTheRestrictionHoldsBetweenSetsAndAfterLogging() async throws {
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/workouts") == true {
                return (200, Data(Self.twoItemWorkout.utf8))
            }
            throw APIError.transport("offline")
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())
        try engine.selectItem(0)
        try engine.beginSet(loadKg: 140, reps: 5)
        _ = await engine.logSet(entry(setIndex: 1), session: session())

        XCTAssertNil(engine.activeSet, "the set is logged")
        XCTAssertFalse(engine.canLeaveExercise, "the exercise is still active between sets")
        try engine.clearSelection()
        XCTAssertEqual(engine.selectedItem?.orderIndex, 0)
    }

    func testEndingTheExerciseReleasesTheListAndAllowsTheNextOne() async throws {
        let transport = AsyncStubTransport { _ in (200, Data(Self.twoItemWorkout.utf8)) }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())
        try engine.selectItem(0)
        try engine.beginSet(loadKg: 140, reps: 5)

        try engine.doneWithExercise()

        XCTAssertTrue(engine.canLeaveExercise)
        XCTAssertNil(engine.selectedItem)
        XCTAssertNil(engine.activeSet)
        try engine.selectItem(1)
        try engine.beginSet(loadKg: 100, reps: 8)
        XCTAssertEqual(engine.selectedItem?.orderIndex, 1)
        XCTAssertEqual(engine.activeSet?.planItemIndex, 1)
    }

    func testConcurrentFlushesSubmitEachOperationOnce() async throws {
        final class Mode { var failing = true; var setRequests = 0 }
        let mode = Mode()
        let gate = TestGate()
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/workouts") == true {
                return (200, Data(Self.twoItemWorkout.utf8))
            }
            if request.url?.path.hasSuffix("/execution-events") == true {
                return (200, Data(Self.eventsAccepted.utf8))
            }
            if request.url?.path.hasSuffix("/sets") == true {
                mode.setRequests += 1
                if mode.failing { throw APIError.transport("offline") }
                await gate.wait()
                return (200, Data(Fixtures.workoutWithSet.utf8))
            }
            throw APIError.transport("offline")
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())
        try engine.selectItem(0)
        _ = await engine.logSet(entry(setIndex: 1), session: session())
        XCTAssertEqual(engine.pendingCount, 1)

        mode.failing = false
        mode.setRequests = 0
        async let first = engine.flush(session: session())
        async let second = engine.flush(session: session())
        // Let both flushes reach the blocked set request, then release it.
        for _ in 0..<200 where mode.setRequests == 0 {
            await Task.yield()
        }
        await gate.openGate()
        _ = await (first, second)

        XCTAssertEqual(engine.pendingCount, 0)
        XCTAssertEqual(mode.setRequests, 1, "one submission for the single queued set")
    }

    func testRevisionIsNotAppliedWhenTheQueueCannotFlush() async throws {
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/execution") == true {
                return (200, Data(Self.executionPayload(revision: 1, loadKg: 150).utf8))
            }
            if request.url?.path.hasSuffix("/workouts") == true {
                return (200, Data(Self.watchWorkout.utf8))
            }
            throw APIError.transport("offline")
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())
        try engine.selectItem(0)
        try engine.beginSet(loadKg: 140, reps: 5)

        _ = await engine.reconcile(session: session())
        XCTAssertFalse(engine.planUpdated, "a failed flush must not fetch a snapshot")
        XCTAssertEqual(engine.workout?.plan?.items.first?.loadKg, 140)

        _ = await engine.logSet(entry(setIndex: 1), session: session())

        XCTAssertEqual(engine.pendingCount, 1, "the set is still queued")
        XCTAssertEqual(
            engine.workout?.plan?.items.first?.loadKg,
            140,
            "the revision waits for a clean flush"
        )
        XCTAssertFalse(engine.planUpdated)
        guard case .addSet(let queued)? = try store.load().operations.first(where: {
            $0.kind == .addSet
        })?.body else {
            return XCTFail("the offline set is preserved")
        }
        XCTAssertEqual(queued.planItemIndex, 0)
        XCTAssertNotNil(queued.performedAt)
    }

    func testCancellingTheActiveSetAlsoAppliesTheDeferredRevision() async throws {
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/execution") == true {
                return (200, Data(Self.executionPayload(revision: 1, loadKg: 150).utf8))
            }
            if request.url?.path.hasSuffix("/execution-events") == true {
                return (200, Data(Self.eventsAccepted.utf8))
            }
            return (200, Data(Self.watchWorkout.utf8))
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())
        try engine.selectItem(0)
        try engine.beginSet(loadKg: 140, reps: 5)
        _ = await engine.reconcile(session: session())
        XCTAssertTrue(engine.planUpdated)

        try engine.cancelActiveSet()

        XCTAssertNil(engine.activeSet)
        XCTAssertEqual(engine.workout?.plan?.items.first?.loadKg, 150)
        XCTAssertFalse(engine.planUpdated)
    }

    func testExecutionEnvelopeDecodesTheOwner() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = Self.executionPayload(owner: "watch-1", revision: 1)
        let response = try decoder.decode(
            ExecutionAnalyticsResponse.self, from: Data(payload.utf8)
        )
        XCTAssertEqual(response.ownerDeviceId, "watch-1", payload)
        XCTAssertEqual(response.planRevision, 1)
        XCTAssertNotNil(response.plan)
    }

    func testSetDurationAndRestUseTheServerClock() throws {
        let serverStart = Date(timeIntervalSince1970: 1_800_000_000)
        for offset in [0.0, 300.0, -300.0] {
            var record = WatchSessionRecord(
                sessionUUID: "session-\(offset)",
                startedAt: serverStart,
                clockOffsetSeconds: offset
            )
            record.activeSet = ActiveSet(
                localSetID: "set-1", planItemIndex: 0, setIndex: 1, startedAt: serverStart
            )
            record.rest = RestInterval(startedAt: serverStart, prescribedSeconds: 120)
            // Sixty server seconds after the start, expressed in the local clock.
            let localNow = serverStart.addingTimeInterval(60 - offset)

            XCTAssertEqual(record.serverNow(at: localNow), serverStart.addingTimeInterval(60))
            XCTAssertEqual(
                record.setDuration(setStartedAt: serverStart, at: localNow), 60, accuracy: 0.01,
                "set duration with offset \(offset)"
            )
            XCTAssertEqual(
                record.restRemaining(at: localNow) ?? -1, 60, accuracy: 0.01,
                "rest countdown with offset \(offset)"
            )
            XCTAssertFalse(record.restIsComplete(at: localNow))
            XCTAssertTrue(
                record.restIsComplete(at: serverStart.addingTimeInterval(121 - offset)),
                "rest finishes on time with offset \(offset)"
            )
        }
    }

    func testMissingOwnershipIsNeverPermissionToWrite() async throws {
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/execution") == true {
                return (200, Data(Self.executionPayload(owner: nil).utf8))
            }
            return (200, Data(Self.watchWorkout.utf8))
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())
        try engine.selectItem(0)

        _ = await engine.reconcile(session: session())

        XCTAssertEqual(engine.phase, WatchExecutionPhase.readOnly)
        let result = await engine.logSet(entry(setIndex: 1), session: session())
        XCTAssertFalse(result.persisted)
    }

    func testMissingDeviceIdentityIsReadOnly() async throws {
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/execution") == true {
                return (200, Data(Self.executionPayload(owner: "watch-1").utf8))
            }
            return (200, Data(Self.watchWorkout.utf8))
        }
        let engine = makeEngine(transport: transport)
        let anonymous = IOSSession(baseURL: URL(string: "http://home.local:8000")!, token: "token")
        _ = await engine.start(issuedPlanID: "plan-1", session: anonymous)

        _ = await engine.reconcile(session: anonymous)

        XCTAssertEqual(engine.phase, WatchExecutionPhase.readOnly)
    }

    func testStartWithoutConfirmedOwnershipIsReadOnly() async throws {
        let json = Self.watchWorkout.replacingOccurrences(
            of: "\"owner_device_id\": \"watch-1\",", with: ""
        )
        let transport = AsyncStubTransport { _ in (200, Data(json.utf8)) }
        let engine = makeEngine(transport: transport)

        _ = await engine.start(issuedPlanID: "plan-1", session: session())

        XCTAssertEqual(engine.phase, WatchExecutionPhase.readOnly)
        XCTAssertNotNil(engine.workout, "the session is kept, not discarded")
    }

    func testReconciliationRestoresWritabilityAfterOwnershipIsConfirmed() async throws {
        final class OwnerBox {
            var value: String?
            var requests = 0
            var seen: [String] = []
        }
        let box = OwnerBox()
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/execution") == true {
                box.requests += 1
                box.seen.append(box.value ?? "nil")
                return (200, Data(Self.executionPayload(owner: box.value).utf8))
            }
            return (200, Data(Self.watchWorkout.utf8))
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())

        _ = await engine.reconcile(session: session())
        XCTAssertEqual(engine.phase, WatchExecutionPhase.readOnly)

        box.value = "watch-1"
        _ = await engine.reconcile(session: session())
        XCTAssertEqual(
            engine.phase, WatchExecutionPhase.active,
            "error=\(engine.lastError ?? "nil") requests=\(box.requests) seen=\(box.seen)"
        )
    }

    // MARK: - Reconciliation

    func testReconciliationKeepsAnOwnedInProgressSessionActive() async throws {
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/execution") == true {
                return (200, Data(Self.executionPayload(owner: "watch-1").utf8))
            }
            return (200, Data(Self.watchWorkout.utf8))
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())

        let stop = await engine.reconcile(session: session())

        XCTAssertEqual(stop, .allSent)
        XCTAssertEqual(engine.phase, .active)
    }

    func testReconciliationGoesReadOnlyWhenThePhoneOwnsTheSession() async throws {
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/execution") == true {
                return (200, Data(Self.executionPayload(owner: "phone-1").utf8))
            }
            return (200, Data(Self.watchWorkout.utf8))
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())

        _ = await engine.reconcile(session: session())

        XCTAssertEqual(engine.phase, WatchExecutionPhase.readOnly)
        let result = await engine.logSet(entry(setIndex: 1), session: session())
        XCTAssertFalse(result.persisted, "a read-only watch cannot capture")
        XCTAssertEqual(try store.load().operations.count, 0)
    }

    func testReconciliationEndsWhenTheServerCompletedTheWorkout() async throws {
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/execution") == true {
                return (200, Data(Self.executionPayload(status: "completed").utf8))
            }
            return (200, Data(Self.watchWorkout.utf8))
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())

        _ = await engine.reconcile(session: session())

        XCTAssertEqual(engine.phase, WatchExecutionPhase.ended(.completed))
        XCTAssertNotNil(engine.completedSetCount >= 0 ? engine.workout : nil)
    }

    func testNotOwnerDuringFlushTurnsTheSessionReadOnly() async throws {
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/workouts") == true {
                return (200, Data(Self.watchWorkout.utf8))
            }
            let body = "{\"error\":\"not yours\",\"code\":\"not_owner\"}"
            return (409, Data(body.utf8))
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())

        let result = await engine.logSet(entry(setIndex: 1), session: session())

        XCTAssertTrue(result.persisted, "the set stays local")
        XCTAssertEqual(result.stop, .conflict(code: "not_owner", message: "not yours"))
        XCTAssertEqual(engine.phase, WatchExecutionPhase.readOnly)
    }

    // MARK: - Phase 6.6 corrections

    func testPlanRowsAreReadOnlyAndDoNotBypassTheExerciseLock() async throws {
        let transport = AsyncStubTransport { _ in (200, Data(Self.twoItemWorkout.utf8)) }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())
        try engine.selectItem(0)
        try engine.beginSet(loadKg: 140, reps: 5)
        let active = engine.activeSet
        let selected = engine.selectedItem?.orderIndex

        let rows = engine.planRows

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].status, .current)
        XCTAssertEqual(rows[1].status, .upcoming)
        XCTAssertEqual(engine.activeSet, active)
        XCTAssertEqual(engine.selectedItem?.orderIndex, selected)
        try engine.selectItem(1)
        XCTAssertEqual(engine.selectedItem?.orderIndex, selected, "Plan cannot switch exercises")
        XCTAssertEqual(engine.activeSet, active)
    }

    func testPlanRowsDistinguishCompletedAndNextExercise() async throws {
        let completedWorkout = Self.twoItemWorkout.replacingOccurrences(
            of: #""sets": []"#,
            with: #""sets": [{"set_id": 1, "exercise_id": "competition_squat", "set_index": 1, "plan_item_index": 0, "load_kg": 140.0, "reps": 5, "rir": 2, "source": "manual"}]"#
        )
        let transport = AsyncStubTransport { _ in
            (200, Data(completedWorkout.utf8))
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())

        let rows = engine.planRows
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].status, .completed)
        XCTAssertEqual(rows[1].status, .upcoming)
        XCTAssertEqual(engine.nextPlanItem?.orderIndex, 1)
    }

    func testReconcileStopsWhenTheFlushFails() async throws {
        final class Probe { var fetchedExecution = false }
        let probe = Probe()
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/workouts") == true {
                return (200, Data(Self.twoItemWorkout.utf8))
            }
            if request.url?.path.hasSuffix("/execution") == true {
                probe.fetchedExecution = true
                return (200, Data(Self.executionPayload(loadKg: 150).utf8))
            }
            throw APIError.transport("offline")
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())
        try engine.selectItem(0)
        _ = await engine.logSet(entry(setIndex: 1), session: session())
        XCTAssertEqual(engine.pendingCount, 1, "the set stays queued with its events")

        let stop = await engine.reconcile(session: session())

        XCTAssertTrue(stop.isRetryable)
        XCTAssertFalse(probe.fetchedExecution, "a failed flush must not apply a snapshot")
        XCTAssertEqual(engine.pendingCount, 1)
        XCTAssertEqual(engine.workout?.plan?.items.first?.loadKg, 140)
    }

    func testAbandonedStatusMapsToAnExplicitReason() async throws {
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/execution") == true {
                return (200, Data(Self.executionPayload(status: "abandoned").utf8))
            }
            return (200, Data(Self.watchWorkout.utf8))
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())

        _ = await engine.reconcile(session: session())

        XCTAssertEqual(engine.phase, .ended(.abandoned))
        XCTAssertEqual(WatchEndedReason.abandoned.title, "Workout abandoned elsewhere")
        XCTAssertTrue(WatchEndedReason.abandoned.message.contains("abandoned on another device"))
        XCTAssertEqual(WatchEndedReason(status: "completed"), .completed)
    }

    func testStaleFlagFromTheAuthoritativeSnapshotIsExposed() async throws {
        let payload = Self.executionPayload()
            .replacingOccurrences(of: #""stale":false"#, with: #""stale":true"#)
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/execution") == true {
                return (200, Data(payload.utf8))
            }
            return (200, Data(Self.watchWorkout.utf8))
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())

        _ = await engine.reconcile(session: session())

        XCTAssertTrue(engine.isStale)
    }

    // MARK: - Revision and mismatch

    func testANewerRevisionIsAppliedWhenIdle() async throws {
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/execution") == true {
                return (200, Data(Self.executionPayload(revision: 1, loadKg: 150).utf8))
            }
            return (200, Data(Self.watchWorkout.utf8))
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())

        _ = await engine.reconcile(session: session())

        XCTAssertEqual(engine.workout?.plan?.items.first?.loadKg, 150)
        XCTAssertEqual(engine.sessionRecord?.planRevision, 1)
        XCTAssertFalse(engine.planUpdated)
        XCTAssertFalse(try store.load().operations.contains { $0.kind == .executionEvents })
    }

    func testANewerRevisionWaitsForAnIdlePoint() async throws {
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/execution") == true {
                return (200, Data(Self.executionPayload(revision: 1, loadKg: 150).utf8))
            }
            if request.url?.path.hasSuffix("/execution-events") == true {
                return (200, Data(Self.eventsAccepted.utf8))
            }
            if request.url?.path.hasSuffix("/sets") == true {
                return (200, Data(Fixtures.workoutWithSet.utf8))
            }
            return (200, Data(Self.watchWorkout.utf8))
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())
        try engine.selectItem(0)
        try engine.beginSet(loadKg: 140, reps: 5)

        _ = await engine.reconcile(session: session())

        XCTAssertEqual(engine.workout?.plan?.items.first?.loadKg, 140, "not under the lifter's hands")
        XCTAssertTrue(engine.planUpdated)
        XCTAssertNotNil(engine.activeSet, "refresh preserves the running set")
        XCTAssertEqual(engine.selectedItem?.orderIndex, 0, "refresh preserves the exercise")

        _ = await engine.logSet(entry(setIndex: 1), session: session())

        XCTAssertEqual(engine.workout?.plan?.items.first?.loadKg, 150)
        XCTAssertFalse(engine.planUpdated)
    }

    func testAnOlderRevisionIsIgnored() async throws {
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/execution") == true {
                return (200, Data(Self.executionPayload(revision: 0, loadKg: 999).utf8))
            }
            return (200, Data(Self.watchWorkout.utf8))
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())
        try engine.selectItem(0)

        _ = await engine.reconcile(session: session())

        XCTAssertEqual(engine.workout?.plan?.items.first?.loadKg, 140)
        XCTAssertNotEqual(engine.workout?.plan?.items.first?.loadKg, 999)
    }

    func testPlanItemMismatchRetriesOffPlanAndKeepsTheSet() async throws {
        final class SetCounter { var attempts = 0 }
        let counter = SetCounter()
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/sets") == true {
                counter.attempts += 1
                if counter.attempts == 1 {
                    let body = "{\"error\":\"the plan item changed\",\"code\":\"plan_item_mismatch\"}"
                    return (409, Data(body.utf8))
                }
                return (200, Data(Fixtures.workoutWithSet.utf8))
            }
            if request.url?.path.hasSuffix("/execution-events") == true {
                return (200, Data(Self.eventsAccepted.utf8))
            }
            return (200, Data(Self.watchWorkout.utf8))
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())
        try engine.selectItem(0)

        let result = await engine.logSet(entry(setIndex: 1), session: session())

        XCTAssertTrue(result.persisted)
        XCTAssertEqual(result.stop, .allSent)
        XCTAssertEqual(counter.attempts, 2, "exactly one off-plan retry")
        XCTAssertEqual(engine.workout?.sets?.count, 1, "the set is preserved")
        XCTAssertEqual(engine.sessionRecord?.offPlanNoted, true)
        XCTAssertEqual(engine.pendingCount, 0)

        let eventsRequest = try XCTUnwrap(
            transport.requests.last { $0.url?.path.hasSuffix("/execution-events") == true }
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(eventsRequest.httpBody))
                as? [String: Any]
        )
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        let completed = try XCTUnwrap(
            events.first { ($0["event_type"] as? String) == "set_completed" }
        )
        XCTAssertNil(completed["plan_item_index"])
        let payload = try XCTUnwrap(completed["payload"] as? [String: Any])
        XCTAssertEqual(payload["original_plan_item_index"] as? Int, 0)
    }

    // MARK: - Selection

    func testSelectingAnExerciseEmitsNothingUntilASetStarts() async throws {
        let transport = AsyncStubTransport { request in
            (200, Data(Self.watchWorkout.utf8))
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())

        try engine.selectItem(0)

        XCTAssertEqual(engine.selectedItem?.orderIndex, 0)
        XCTAssertEqual(engine.pendingEventCount, 0)
        XCTAssertNil(engine.exerciseItemIndex)
    }

    func testSwitchingExerciseIsBlockedUntilTheActiveOneEnds() async throws {
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/workouts") == true {
                return (200, Data(Self.twoItemWorkout.utf8))
            }
            throw APIError.transport("offline")
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())
        try engine.selectItem(0)
        try engine.beginSet(loadKg: 140, reps: 5)

        try engine.selectItem(1)
        XCTAssertEqual(engine.selectedItem?.orderIndex, 0, "the active exercise wins")
        XCTAssertEqual(engine.exerciseItemIndex, 0)

        try engine.doneWithExercise()
        try engine.selectItem(1)
        try engine.beginSet(loadKg: 100, reps: 8)
        XCTAssertEqual(engine.selectedItem?.orderIndex, 1)
        XCTAssertEqual(engine.exerciseItemIndex, 1)

        let capture = try store.load()
        let types = capture.operations.flatMap { operation -> [ExecutionEventType] in
            guard case .executionEvents(let events) = operation.body else { return [] }
            return events.map(\.eventType)
        }
        // Ending an exercise during an unlogged set cancels that set, so its start event is gone.
        XCTAssertEqual(types, [
            .exerciseStarted, .exerciseCompleted,
            .exerciseStarted, .setStarted,
        ])
    }

    func testBackToListClearsTheSelection() async throws {
        let transport = AsyncStubTransport { request in
            (200, Data(Self.watchWorkout.utf8))
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())
        try engine.selectItem(0)

        try engine.clearSelection()

        XCTAssertNil(engine.selectedItem)
        XCTAssertNil(try store.load().session?.selectedItemIndex)
    }

    // MARK: - Fixups: rest at finish, drafts, exercise lifecycle

    func testFinishClosesAnOpenRestWithATerminalEvent() async throws {
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/workouts") == true {
                return (200, Data(Self.watchWorkout.utf8))
            }
            throw APIError.transport("offline")
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())
        try engine.startRest(seconds: 120, planItemIndex: 0)

        let stop = await engine.finish(sessionRpe: 8, session: session())

        XCTAssertTrue(stop.isRetryable)
        XCTAssertEqual(engine.phase, .finishing)
        let capture = try store.load()
        XCTAssertNotNil(capture.session?.rest?.endedAt, "the rest is closed, not deleted")
        let types = capture.operations.flatMap { operation -> [ExecutionEventType] in
            guard case .executionEvents(let events) = operation.body else { return [] }
            return events.map(\.eventType)
        }
        XCTAssertEqual(types.filter { $0 == .restCompleted }.count, 1)
        XCTAssertFalse(types.contains(.restSkipped))
    }

    func testFinishDropsTheStartEventOfASetThatWasNeverLogged() async throws {
        let transport = AsyncStubTransport { request in
            (200, Data(Self.watchWorkout.utf8))
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())
        try engine.selectItem(0)
        try engine.beginSet(loadKg: 140, reps: 5)
        let token = try XCTUnwrap(engine.activeSet?.localSetID)

        _ = await engine.finish(sessionRpe: 8, session: session())

        let capture = try store.load()
        XCTAssertNil(capture.session?.activeSet)
        let locals = capture.operations.flatMap { operation -> [String?] in
            guard case .executionEvents(let events) = operation.body else { return [] }
            return events.map(\.localSetId)
        }
        XCTAssertFalse(locals.contains(token), "a set that never happened leaves no start event")
    }

    func testSetDraftSurvivesARelaunch() async throws {
        let transport = AsyncStubTransport { request in
            (200, Data(Self.watchWorkout.utf8))
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())
        try engine.selectItem(0)
        try engine.beginSet(loadKg: 140, reps: 5)
        try engine.updateActiveSetDraft(loadKg: 142.5, reps: 4)

        let relaunched = makeEngine(transport: transport)
        try relaunched.restore()

        let active = try XCTUnwrap(relaunched.activeSet)
        XCTAssertEqual(active.loadKg, 142.5)
        XCTAssertEqual(active.reps, 4)
        XCTAssertEqual(relaunched.phase, .active)
    }

    func testElapsedTimeUsesThePersistedServerOffset() throws {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let record = WatchSessionRecord(
            sessionUUID: "session-1",
            startedAt: started,
            clockOffsetSeconds: -300
        )
        // The local clock runs five minutes ahead, so 360 local seconds are 60 server seconds.
        XCTAssertEqual(record.elapsedSeconds(at: started.addingTimeInterval(360)), 60, accuracy: 0.5)
    }

    func testExerciseEventsStartOnTheFirstSetAndEndOnDone() async throws {
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/workouts") == true {
                return (200, Data(Self.twoItemWorkout.utf8))
            }
            throw APIError.transport("offline")
        }
        let engine = makeEngine(transport: transport)
        _ = await engine.start(issuedPlanID: "plan-1", session: session())

        try engine.selectItem(0)
        try engine.beginSet(loadKg: 140, reps: 5)
        _ = await engine.logSet(
            WatchExecutionEngine.SetEntry(
                exerciseId: "competition_squat",
                planItemIndex: 0,
                setIndex: 1,
                loadKg: 140,
                reps: 5,
                rir: 2
            ),
            session: session()
        )
        try engine.doneWithExercise()
        try engine.selectItem(1)
        try engine.beginSet(loadKg: 100, reps: 8)
        try engine.doneWithExercise()

        let capture = try store.load()
        let events = capture.operations.flatMap { operation -> [ExecutionEvent] in
            guard case .executionEvents(let batch) = operation.body else { return [] }
            return batch
        }
        XCTAssertEqual(events.map(\.eventType), [
            .exerciseStarted, .setStarted, .setCompleted,
            .exerciseCompleted, .exerciseStarted,
            .exerciseCompleted,
        ])
        XCTAssertEqual(events.map(\.planItemIndex), [0, 0, 0, 0, 1, 1])
    }

    // MARK: - Finish and discard

    func testFinishPersistsTheIntentBeforeTheServerCallAndQueuesIt() async throws {
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/workouts") == true {
                return (200, Data(Self.watchWorkout.utf8))
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
            return (200, Data(Self.watchWorkout.utf8))
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
        _ = try store.setActiveWorkout(try decode(Self.watchWorkout))
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

    private static let twoItemWorkout = #"""
    {
      "workout_id": "workout-1",
      "for_date": "2026-11-07",
      "session_type": "squat",
      "status": "in_progress",
      "plan": {
        "for_date": "2026-11-07",
        "session_type": "squat",
        "items": [
          {"order_index": 0, "exercise_id": "competition_squat", "sets": 1,
           "reps_low": 5, "load_kg": 140.0, "rir_target": 2, "rest_s": 120},
          {"order_index": 1, "exercise_id": "bench_press", "sets": 1,
           "reps_low": 8, "load_kg": 100.0, "rir_target": 2, "rest_s": 120}
        ]
      },
      "sets": [],
      "forms": [],
      "owner_device_id": "watch-1",
      "started_at": "2026-11-07T16:00:00+00:00"
    }
    """#

    private static func executionPayload(
        status: String = "in_progress",
        owner: String? = "watch-1",
        revision: Int? = 0,
        loadKg: Double = 140
    ) -> String {
        let ownerJSON = owner.map { "\"\($0)\"" } ?? "null"
        let revisionJSON = revision.map(String.init) ?? "null"
        let endedJSON = status == "in_progress" ? "null" : "\"2026-11-07T17:00:00+00:00\""
        return """
        {"workout_id":"workout-1","status":"\(status)",
         "started_at":"2026-11-07T16:00:00+00:00","ended_at":\(endedJSON),
         "total_elapsed_s":0,"events":[],"sets":[],"rests":[],"exercises":[],
         "summary":{"active_lifting_s":0,"recorded_recovery_s":0,
           "exercise_transition_s":0,"unclassified_s":0,"total_elapsed_s":0},
         "data_quality":{"event_count":0,"sets_with_duration":0,
           "rests_with_actual":0,"rests_without_prescribed":0,"workout_has_end":false},
         "owner_device_id":\(ownerJSON),"plan_revision":\(revisionJSON),
         "last_activity_at":"2026-11-07T16:00:00+00:00","stale":false,
         "plan":{"for_date":"2026-11-07","session_type":"squat",
           "items":[{"order_index":0,"exercise_id":"competition_squat","sets":3,
             "reps_low":5,"load_kg":\(loadKg),"rir_target":2}]}}
        """
    }

    private static let eventsAccepted = #"""
    {"workout_id":"workout-1","accepted":[],"duplicates":[],
     "received_at":"2026-11-07T16:00:01+00:00"}
    """#

    /// The shared workout fixture, owned by this watch rather than the phone. The phone suites
    /// need a phone-owned copy because mirror mode blocks their writes.
    private static var watchWorkout: String {
        Fixtures.workoutInProgress.replacingOccurrences(
            of: #""owner_device_id": "device-1""#,
            with: #""owner_device_id": "watch-1""#
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
