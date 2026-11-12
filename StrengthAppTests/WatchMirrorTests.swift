import XCTest
import WatchConnectivity

@testable import StrengthApp
import StrengthCore

/// Phase 6.6: the phone mirror, the plan-revision push, the take-over handshake and the watch's
/// form-rating/VBT capture, exercised without a watch or WatchConnectivity runtime (contract
/// §10, §16).
@MainActor
final class WatchMirrorTests: XCTestCase {
    private var fileURL: URL!
    private var clock: Date!
    private var store: OfflineCaptureStore!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-mirror-\(UUID().uuidString).json")
        clock = ServerClock.parse("2026-11-08T10:00:00+00:00")!
        store = OfflineCaptureStore(fileURL: fileURL, now: { [unowned self] in self.clock })
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    // MARK: - Ownership

    func testMirrorPolicyFollowsTheSessionOwner() throws {
        // A row with no owner predates ownership; it keeps the permissive behaviour (contract §9).
        XCTAssertFalse(MirrorPolicy.isMirror(workout: nil, phoneDeviceID: "phone-1"))
        XCTAssertFalse(MirrorPolicy.isMirror(
            workout: try workout(owner: nil, revision: 0),
            phoneDeviceID: "phone-1"
        ))

        let watchOwned = try workout(owner: "watch-1", revision: 0)
        XCTAssertTrue(MirrorPolicy.isMirror(workout: watchOwned, phoneDeviceID: "phone-1"))
        XCTAssertFalse(MirrorPolicy.isMirror(workout: watchOwned, phoneDeviceID: "watch-1"))
        // A phone that cannot prove its identity must never be allowed to write.
        XCTAssertTrue(MirrorPolicy.isMirror(workout: watchOwned, phoneDeviceID: nil))
    }

    // MARK: - Payload

    func testExecutionPayloadRoundTripsAndRejectsAnotherSchema() throws {
        let payload = try XCTUnwrap(RemoteExecutionPayload(
            workout: try workout(owner: "watch-1", revision: 3),
            revision: 3
        ))
        let json = try XCTUnwrap(payload.encodedString())
        XCTAssertTrue(json.contains(#""plan_revision":3"#), json)

        let decoded = try XCTUnwrap(RemoteExecutionPayload.decode(json))
        XCTAssertEqual(decoded.planRevision, 3)
        XCTAssertEqual(decoded.ownerDeviceId, "watch-1")
        XCTAssertEqual(decoded.plan.items.first?.loadKg, 140)

        let futureSchema = json.replacingOccurrences(of: #""schema":1"#, with: #""schema":2"#)
        XCTAssertNil(RemoteExecutionPayload.decode(futureSchema))
        XCTAssertNil(RemoteExecutionPayload.decode("not json"))
    }

    // MARK: - Applying a push

    func testApplyRemoteAppliesOnlyNewerRevisionsForThisWorkout() async throws {
        let engine = makeEngine()
        _ = await engine.start(issuedPlanID: "plan-1", session: session())
        XCTAssertEqual(engine.phase, .active)

        XCTAssertTrue(engine.applyRemote(try push(revision: 2, loadKg: 150), deviceID: "watch-1"))
        XCTAssertEqual(engine.workout?.plan?.items.first?.loadKg, 150)
        XCTAssertEqual(engine.sessionRecord?.planRevision, 2)
        // The plan swap must not drop ownership; the watch would otherwise forget who may write.
        XCTAssertEqual(engine.workout?.ownerDeviceId, "watch-1")

        XCTAssertFalse(engine.applyRemote(try push(revision: 1, loadKg: 160), deviceID: "watch-1"))
        XCTAssertEqual(engine.workout?.plan?.items.first?.loadKg, 150)

        XCTAssertFalse(engine.applyRemote(
            try push(revision: 5, loadKg: 170, workoutId: "workout-2"),
            deviceID: "watch-1"
        ))
        XCTAssertEqual(engine.workout?.plan?.items.first?.loadKg, 150)
    }

    func testPlanPushIsDeferredWhileASetIsInProgress() async throws {
        let engine = makeEngine()
        _ = await engine.start(issuedPlanID: "plan-1", session: session())
        try engine.selectItem(0)
        try engine.beginSet()
        XCTAssertNotNil(engine.activeSet)

        XCTAssertTrue(engine.applyRemote(try push(revision: 2, loadKg: 150), deviceID: "watch-1"))
        XCTAssertTrue(engine.planUpdated)
        XCTAssertEqual(
            engine.workout?.plan?.items.first?.loadKg,
            140,
            "the prescribed target must not move under the lifter's fingers"
        )

        try engine.doneWithExercise()

        XCTAssertNil(engine.activeSet)
        XCTAssertFalse(engine.planUpdated)
        XCTAssertEqual(engine.workout?.plan?.items.first?.loadKg, 150)
    }

    func testAPhoneOwnedPayloadMakesTheWatchReadOnly() async throws {
        let engine = makeEngine()
        _ = await engine.start(issuedPlanID: "plan-1", session: session())

        XCTAssertTrue(engine.applyRemote(
            try push(revision: 2, loadKg: 150, owner: "phone-1"),
            deviceID: "watch-1"
        ))
        XCTAssertEqual(engine.phase, .readOnly)

        let set = await engine.logSet(
            WatchExecutionEngine.SetEntry(
                exerciseId: "competition_squat",
                planItemIndex: 0,
                setIndex: 1,
                loadKg: 140,
                reps: 3,
                rir: 2
            ),
            session: session()
        )
        XCTAssertFalse(set.persisted)
    }

    // MARK: - Push transport

    func testPlanEditPayloadIsQueuedToTheWatch() throws {
        let suite = "WatchMirrorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let pairedStore = PairedStore(defaults: defaults)
        pairedStore.homeServerURL = "http://home.local:8000"
        let connectivity = RecordingConnectivity()
        let coordinator = WatchPairingCoordinator(
            client: IOSAPIClient(transport: StubTransport { _ in (500, Data()) }),
            store: pairedStore,
            connectivity: connectivity
        )
        coordinator.start(
            session: session(deviceID: "phone-1"),
            homeBaseURL: "http://home.local:8000"
        )

        XCTAssertTrue(coordinator.pushExecution(try workout(owner: "watch-1", revision: 4)))

        let userInfo = try XCTUnwrap(connectivity.userInfos.last)
        let json = try XCTUnwrap(userInfo["execution"] as? String)
        let payload = try XCTUnwrap(RemoteExecutionPayload.decode(json))
        XCTAssertEqual(payload.planRevision, 4)
        XCTAssertEqual(payload.workoutId, "workout-1")

        // A workout the server did not stamp with a revision cannot be pushed coherently.
        XCTAssertFalse(coordinator.pushExecution(try workout(owner: "watch-1", revision: nil)))
    }

    // MARK: - Watch capture

    func testWatchSetCarriesMeanVelocityIntoTheQueuedOperation() async throws {
        let json = workoutJSON(owner: "watch-1")
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/workouts") == true {
                return (200, Data(json.utf8))
            }
            throw APIError.transport("offline")
        }
        let engine = WatchExecutionEngine(
            client: IOSAPIClient(transport: transport),
            store: store,
            now: { [unowned self] in self.clock }
        )
        _ = await engine.start(issuedPlanID: "plan-1", session: session())
        try engine.selectItem(0)

        let result = await engine.logSet(
            WatchExecutionEngine.SetEntry(
                exerciseId: "competition_squat",
                planItemIndex: 0,
                setIndex: 1,
                loadKg: 140,
                reps: 3,
                rir: 2,
                velocityMps: 0.62
            ),
            session: session()
        )

        XCTAssertTrue(result.persisted)
        let capture = try store.load()
        let operation = try XCTUnwrap(capture.operations.first { $0.kind == .addSet })
        guard case .addSet(let body) = operation.body else {
            return XCTFail("expected an add-set operation, got (operation.kind)")
        }
        XCTAssertEqual(body.velocityMps, 0.62)
    }

    func testWatchFormRatingIsQueuedAndReplayedLikeASet() async throws {
        let json = workoutJSON(owner: "watch-1")
        let transport = AsyncStubTransport { request in
            if request.url?.path.hasSuffix("/workouts") == true {
                return (200, Data(json.utf8))
            }
            throw APIError.transport("offline")
        }
        let engine = WatchExecutionEngine(
            client: IOSAPIClient(transport: transport),
            store: store,
            now: { [unowned self] in self.clock }
        )
        _ = await engine.start(issuedPlanID: "plan-1", session: session())

        let stop = await engine.rateForm(
            exerciseId: "competition_squat",
            rating: 4,
            session: session()
        )

        XCTAssertTrue(stop.isRetryable)
        let capture = try store.load()
        let operation = try XCTUnwrap(capture.operations.first { $0.kind == .rateForm })
        guard case .rateForm(let body) = operation.body else {
            return XCTFail("expected a form-rating operation, got (operation.kind)")
        }
        XCTAssertEqual(body.rating, 4)
        XCTAssertEqual(body.exerciseId, "competition_squat")
    }

    // MARK: - Helpers

    private func session(deviceID: String = "watch-1") -> IOSSession {
        IOSSession(
            baseURL: URL(string: "http://home.local:8000")!,
            token: "token",
            deviceID: deviceID
        )
    }

    private func makeEngine() -> WatchExecutionEngine {
        let json = workoutJSON(owner: "watch-1")
        let transport = AsyncStubTransport { _ in (200, Data(json.utf8)) }
        return WatchExecutionEngine(
            client: IOSAPIClient(transport: transport),
            store: store,
            now: { [unowned self] in self.clock }
        )
    }

    private func push(
        revision: Int,
        loadKg: Double,
        owner: String = "watch-1",
        workoutId: String = "workout-1"
    ) throws -> RemoteExecutionPayload {
        RemoteExecutionPayload(
            workoutId: workoutId,
            status: "in_progress",
            planRevision: revision,
            ownerDeviceId: owner,
            plan: try plan(loadKg: loadKg)
        )
    }

    private func plan(loadKg: Double) throws -> PrescriptionPlan {
        let json = """
        {"for_date": "2026-11-08", "session_type": "squat", "items": [
          {"order_index": 0, "exercise_id": "competition_squat", "sets": 3,
           "reps_low": 3, "reps_high": 5, "load_kg": \(loadKg), "rir_target": 2}
        ]}
        """
        return try decoder().decode(PrescriptionPlan.self, from: Data(json.utf8))
    }

    private func workout(owner: String?, revision: Int?) throws -> WorkoutDetail {
        try decoder().decode(
            WorkoutDetail.self,
            from: Data(workoutJSON(owner: owner, revision: revision).utf8)
        )
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private func workoutJSON(owner: String?, revision: Int? = 0) -> String {
        let ownerJSON = owner.map { #""\#($0)""# } ?? "null"
        let revisionJSON = revision.map(String.init) ?? "null"
        return """
        {
          "workout_id": "workout-1",
          "prescription_id": "prescription-1",
          "for_date": "2026-11-08",
          "session_type": "squat",
          "status": "in_progress",
          "plan": {
            "for_date": "2026-11-08",
            "session_type": "squat",
            "items": [
              {"order_index": 0, "exercise_id": "competition_squat", "sets": 3,
               "reps_low": 3, "reps_high": 5, "load_kg": 140.0, "rir_target": 2}
            ]
          },
          "sets": [],
          "forms": [],
          "owner_device_id": \(ownerJSON),
          "plan_revision": \(revisionJSON),
          "started_at": "2026-11-08T10:00:00+00:00"
        }
        """
    }
}

@MainActor
private final class RecordingConnectivity: WatchConnectivitySession {
    weak var delegate: WatchConnectivitySessionDelegate?
    var isSupported = true
    var isPaired = true
    var isWatchAppInstalled = true
    var activationState: WCSessionActivationState = .activated
    var receivedApplicationContext: [String: Any] = [:]
    private(set) var userInfos: [[String: Any]] = []

    func activate() {
        activationState = .activated
        delegate?.watchConnectivityDidChange()
    }

    func updateApplicationContext(_ context: [String: Any]) throws {}

    func transferUserInfo(_ userInfo: [String: Any]) {
        userInfos.append(userInfo)
    }
}
