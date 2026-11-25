import XCTest
import WatchConnectivity

@testable import StrengthApp
import StrengthCore

@MainActor
final class AppModelTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "com.georgesdibpersonalteam.StrengthApp.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    func test401ClearsTheLocalPairingButKeepsTheServerURL() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PairedStore(defaults: defaults)
        store.serverURL = "http://127.0.0.1:8000"
        store.device = PairingDevice(deviceID: "device-1", label: "iPhone")
        let tokens = InMemoryTokenStore(token: "token-abc")
        let transport = StubTransport { _ in (401, Data()) }
        let model = AppModel(
            client: IOSAPIClient(transport: transport),
            tokens: tokens,
            store: store
        )

        await model.onLaunch()

        XCTAssertEqual(model.phase, .pairing)
        XCTAssertNil(tokens.token)
        XCTAssertNil(store.device)
        XCTAssertEqual(store.serverURL, "http://127.0.0.1:8000")
        XCTAssertEqual(model.serverURLText, "http://127.0.0.1:8000")
        XCTAssertEqual(model.pairingError, APIError.unauthorized.errorDescription)
    }

    func test403AlsoClearsTheLocalPairing() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PairedStore(defaults: defaults)
        store.serverURL = "http://127.0.0.1:8000"
        store.device = PairingDevice(deviceID: "device-1", label: "iPhone")
        let tokens = InMemoryTokenStore(token: "token-abc")
        let transport = StubTransport { _ in (403, Data()) }
        let model = AppModel(
            client: IOSAPIClient(transport: transport),
            tokens: tokens,
            store: store
        )

        await model.onLaunch()

        XCTAssertEqual(model.phase, .pairing)
        XCTAssertNil(tokens.token)
        XCTAssertEqual(model.pairingError, APIError.forbidden.errorDescription)
    }

    func testCachedReadinessSchemaIsAvailableOfflineAndAbsenceUsesTheFallback() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PairedStore(defaults: defaults)
        store.serverURL = "http://127.0.0.1:8000"

        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("readiness-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let cache = ReadinessSchemaCache(fileURL: cacheURL)
        let schema = ReadinessSchema(
            registryId: 9,
            effectiveFrom: "2026-11-24",
            schemaVersion: 1,
            minCoreFields: 2,
            requireAnyOf: ["mood"],
            wearableWeight: 0.2,
            metrics: ReadinessSchema.fallback.metrics
        )
        try cache.save(serverURL: "http://127.0.0.1:8000", schema: schema)

        let cachedModel = AppModel(
            client: IOSAPIClient(transport: StubTransport { _ in (500, Data()) }),
            tokens: InMemoryTokenStore(),
            store: store,
            readinessSchemaCache: cache
        )
        XCTAssertEqual(cachedModel.readinessSchema.registryId, 9)
        XCTAssertEqual(cachedModel.readinessSchemaSource, .cache)

        let fallbackURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("readiness-\(UUID().uuidString).json")
        let fallbackModel = AppModel(
            client: IOSAPIClient(transport: StubTransport { _ in (500, Data()) }),
            tokens: InMemoryTokenStore(),
            store: store,
            readinessSchemaCache: ReadinessSchemaCache(fileURL: fallbackURL)
        )
        XCTAssertNil(fallbackModel.readinessSchema.registryId)
        XCTAssertEqual(fallbackModel.readinessSchemaSource, .fallback)
        XCTAssertEqual(
            fallbackModel.readinessSchema.enabledMetrics.map(\.key),
            ReadinessSchema.fallback.enabledMetrics.map(\.key)
        )
    }

    func testPairStoresTheTokenAndLoadsToday() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PairedStore(defaults: defaults)
        let tokens = InMemoryTokenStore()
        let transport = StubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/pair":
                return (200, Data(Fixtures.pair.utf8))
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrap.utf8))
            case "/api/ios/v1/today":
                return (200, Data(Fixtures.today.utf8))
            default:
                return (404, Data())
            }
        }
        let model = AppModel(
            client: IOSAPIClient(transport: transport),
            tokens: tokens,
            store: store
        )
        model.serverURLText = "http://127.0.0.1:8000/"
        model.pairingCodeText = "1234 5678"
        model.pairingLabelText = "Gym iPhone"

        await model.pair()

        XCTAssertEqual(model.phase, .paired)
        XCTAssertEqual(tokens.token, "token-abc")
        XCTAssertEqual(store.device?.deviceID, "device-1")
        XCTAssertEqual(store.serverURL, "http://127.0.0.1:8000")
        XCTAssertEqual(model.today?.date, "2026-11-07")
        XCTAssertNil(model.pairingError)
        XCTAssertEqual(model.pairedServerURL, "http://127.0.0.1:8000")
    }

    func testInitialPhonePairingImmediatelyEnablesWatchPairing() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PairedStore(defaults: defaults)
        let tokens = InMemoryTokenStore()
        let connectivity = RecordingWatchConnectivity()
        let model = AppModel(
            client: IOSAPIClient(transport: watchTransport()),
            tokens: tokens,
            store: store,
            watchConnectivity: connectivity
        )
        preparePhonePairing(model)

        await model.pair()

        XCTAssertEqual(model.phase, .paired)
        XCTAssertTrue(model.watchPairing.canPair)
        await model.watchPairing.pair()
        XCTAssertEqual(model.watchPairing.link?.deviceID, "watch-1")
        XCTAssertEqual(connectivity.updates.last?["token"] as? String, "watch-token")
    }

    func testExistingPairedLaunchEnablesWatchPairing() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PairedStore(defaults: defaults)
        store.serverURL = "http://127.0.0.1:8000"
        store.device = PairingDevice(deviceID: "device-1", label: "iPhone")
        let tokens = InMemoryTokenStore(token: "token-abc")
        let connectivity = RecordingWatchConnectivity()
        let model = AppModel(
            client: IOSAPIClient(transport: watchTransport()),
            tokens: tokens,
            store: store,
            watchConnectivity: connectivity
        )

        await model.onLaunch()

        XCTAssertEqual(model.phase, .paired)
        XCTAssertTrue(model.watchPairing.canPair)
    }

    func testPhoneRepairResetsAndReinitializesWatchPairing() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PairedStore(defaults: defaults)
        let tokens = InMemoryTokenStore()
        let connectivity = RecordingWatchConnectivity()
        let model = AppModel(
            client: IOSAPIClient(transport: watchTransport()),
            tokens: tokens,
            store: store,
            watchConnectivity: connectivity
        )
        preparePhonePairing(model)
        await model.pair()
        await model.watchPairing.pair()
        XCTAssertEqual(model.watchPairing.link?.deviceID, "watch-1")

        model.forgetDevice()
        preparePhonePairing(model)
        await model.pair()

        XCTAssertEqual(model.phase, .paired)
        XCTAssertNil(model.watchPairing.link)
        XCTAssertTrue(model.watchPairing.canPair)
    }

    func testWatchPairingFailsSafelyWhenHomeWatchEndpointIsUnavailable() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PairedStore(defaults: defaults)
        let tokens = InMemoryTokenStore()
        let connectivity = RecordingWatchConnectivity()
        let transport = StubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/pair":
                return (200, Data(Fixtures.pair.utf8))
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrap.utf8))
            case "/api/ios/v1/today":
                return (200, Data(Fixtures.today.utf8))
            case "/api/ios/v1/devices/watch":
                throw URLError(.cannotConnectToHost)
            default:
                return (404, Data())
            }
        }
        let model = AppModel(
            client: IOSAPIClient(transport: transport),
            tokens: tokens,
            store: store,
            watchConnectivity: connectivity
        )
        preparePhonePairing(model)
        await model.pair()

        await model.watchPairing.pair()

        XCTAssertNil(model.watchPairing.link)
        XCTAssertTrue(model.watchPairing.errorMessage?.contains("Home Server") == true)
    }

    func testRepeatedForegroundDoesNotMintWithoutAPairedWatch() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PairedStore(defaults: defaults)
        let tokens = InMemoryTokenStore()
        let connectivity = RecordingWatchConnectivity()
        var watchMintCount = 0
        let transport = StubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/pair":
                return (200, Data(Fixtures.pair.utf8))
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrap.utf8))
            case "/api/ios/v1/today":
                return (200, Data(Fixtures.today.utf8))
            case "/api/ios/v1/devices/watch":
                watchMintCount += 1
                return (201, Data("{}".utf8))
            default:
                return (404, Data())
            }
        }
        let model = AppModel(
            client: IOSAPIClient(transport: transport),
            tokens: tokens,
            store: store,
            watchConnectivity: connectivity
        )
        preparePhonePairing(model)
        await model.pair()

        await model.appBecameActive()
        await model.appBecameActive()

        XCTAssertEqual(watchMintCount, 0)
        XCTAssertNil(model.watchPairing.link)
    }

    func testOfflineExecutionChangeIsQueuedAndVisible() async {
        let transport = StubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrapPhase2.utf8))
            case "/api/ios/v1/today":
                return (200, Data(executionChangeToday().utf8))
            case "/api/ios/v1/workouts/workout-1/execution":
                throw URLError(.notConnectedToInternet)
            default:
                return (404, Data())
            }
        }
        let journal = MutationJournal(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("execution-change-\(UUID().uuidString).json"))
        let (model, suite) = executionChangeModel(transport: transport, journal: journal)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        await model.onLaunch()
        XCTAssertEqual(model.activeWorkout?.workoutId, "workout-1")

        let recorded = await model.recordExecutionChange(
            workoutId: "workout-1",
            planItemIndex: 0,
            exerciseId: "bench_press",
            idempotencyKey: "change-offline"
        )

        XCTAssertTrue(recorded)
        XCTAssertEqual(model.pendingExecutionChanges.count, 1)
        XCTAssertEqual(model.pendingExecutionChanges.first?.targetId, "workout-1")
        XCTAssertNil(model.executionChangeRejection)
        XCTAssertEqual(model.effectiveExecutionView.substitutions.count, 1)
        XCTAssertEqual(model.effectiveExecutionView.substitutions.first?.localState, "pending")
        XCTAssertTrue(model.executionRows.contains { $0.change?.localState == "pending" })
    }

    func testRejectedExecutionChangeStaysVisibleAsUnresolved() async {
        let transport = StubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrapPhase2.utf8))
            case "/api/ios/v1/today":
                return (200, Data(executionChangeToday().utf8))
            case "/api/ios/v1/workouts/workout-1/execution":
                return (409, Data(#"{"error":"already substituted","code":"execution_change_conflict"}"#.utf8))
            default:
                return (404, Data())
            }
        }
        let journal = MutationJournal(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("execution-change-(UUID().uuidString).json"))
        let (model, suite) = executionChangeModel(transport: transport, journal: journal)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        await model.onLaunch()
        let recorded = await model.recordExecutionChange(
            workoutId: "workout-1",
            planItemIndex: 0,
            exerciseId: "bench_press",
            idempotencyKey: "change-rejected"
        )

        XCTAssertFalse(recorded)
        XCTAssertEqual(model.effectiveExecutionView.substitutions.first?.localState, "rejected")
        XCTAssertTrue(model.executionRows.contains { $0.change?.localState == "rejected" })
        XCTAssertNotNil(model.mutationError)
    }

    func testReplayedExecutionChangePushesThePlanAndFlagsOffPlanSets() async throws {
        let journal = MutationJournal(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("execution-change-\(UUID().uuidString).json"))
        try journal.record(pendingExecutionChange())
        let connectivity = RecordingWatchConnectivity()
        let transport = StubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrapPhase2.utf8))
            case "/api/ios/v1/today":
                return (200, Data(executionChangeToday(staleSet: true).utf8))
            case "/api/ios/v1/workouts/workout-1/execution":
                return (200, Data(executionChangeResponse.utf8))
            default:
                return (404, Data())
            }
        }
        let (model, suite) = executionChangeModel(
            transport: transport, journal: journal, connectivity: connectivity
        )
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        await model.onLaunch()

        XCTAssertEqual(model.executionView?.watermark, 1)
        XCTAssertTrue(model.pendingExecutionChanges.isEmpty)
        XCTAssertEqual(model.unlinkedWatchSets.count, 1)
        XCTAssertEqual(model.unlinkedWatchSets.first?.exerciseId, "competition_squat")

        let execution = connectivity.userInfos.compactMap { $0["execution"] as? String }
        XCTAssertEqual(execution.count, 1)
        let json = try XCTUnwrap(execution.first)
        let payload = try XCTUnwrap(RemoteExecutionPayload.decode(json))
        XCTAssertEqual(payload.workoutId, "workout-1")
        XCTAssertEqual(payload.planRevision, 1)
        XCTAssertEqual(payload.execution?.substitutions.first?.exerciseId, "bench_press")
    }

    func testRejectedExecutionChangeIsKeptForTheWorkoutScreen() async throws {
        let journal = MutationJournal(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("execution-change-\(UUID().uuidString).json"))
        try journal.record(pendingExecutionChange())
        let connectivity = RecordingWatchConnectivity()
        let transport = StubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrapPhase2.utf8))
            case "/api/ios/v1/today":
                return (200, Data(executionChangeToday().utf8))
            case "/api/ios/v1/workouts/workout-1/execution":
                return (400, Data(#"{"code":"validation_failed","error":"cannot substitute a plan item after sets have been logged"}"#.utf8))
            default:
                return (404, Data())
            }
        }
        let (model, suite) = executionChangeModel(
            transport: transport, journal: journal, connectivity: connectivity
        )
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        await model.onLaunch()

        XCTAssertEqual(model.executionChangeRejection?.workoutID, "workout-1")
        XCTAssertTrue(model.executionChangeRejection?.message.contains("cannot substitute") == true)
        XCTAssertTrue(model.pendingExecutionChanges.isEmpty)
        XCTAssertFalse(connectivity.userInfos.contains { $0["execution"] != nil })
    }

    func testConflictedExecutionChangeIsNotOfferedAsQueued() async throws {
        let journal = MutationJournal(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("execution-change-\(UUID().uuidString).json"))
        let entry = pendingExecutionChange()
        try journal.record(entry)
        try journal.markConflict(entry)
        let transport = StubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrapPhase2.utf8))
            case "/api/ios/v1/today":
                return (200, Data(executionChangeToday().utf8))
            default:
                return (404, Data())
            }
        }
        let (model, suite) = executionChangeModel(transport: transport, journal: journal)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        await model.onLaunch()

        XCTAssertEqual(model.activeWorkout?.workoutId, "workout-1")
        // A conflict cannot be replayed, so it must not be presented as a queued change with a retry.
        XCTAssertTrue(model.pendingExecutionChanges.isEmpty)
        XCTAssertEqual(model.conflictedExecutionChanges.count, 1)
        XCTAssertEqual(model.conflictedExecutionChanges.first?.targetId, "workout-1")
    }

    func testPairingInputErrorsDoNotCreateADevice() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PairedStore(defaults: defaults)
        let tokens = InMemoryTokenStore()
        let transport = StubTransport { _ in
            XCTFail("the client must not be called for invalid input")
            return (500, Data())
        }
        let model = AppModel(
            client: IOSAPIClient(transport: transport),
            tokens: tokens,
            store: store
        )
        model.serverURLText = "http://127.0.0.1:8000"
        model.pairingCodeText = "1234"

        await model.pair()

        XCTAssertEqual(model.phase, .loading)
        XCTAssertNil(tokens.token)
        XCTAssertEqual(
            model.pairingError,
            APIError.invalidPairingCode.errorDescription
        )
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testForgetDeviceKeepsTheServerURLForRePairing() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PairedStore(defaults: defaults)
        store.serverURL = "http://127.0.0.1:8000"
        store.device = PairingDevice(deviceID: "device-1", label: "iPhone")
        let tokens = InMemoryTokenStore(token: "token-abc")
        let transport = StubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrap.utf8))
            case "/api/ios/v1/today":
                return (200, Data(Fixtures.today.utf8))
            default:
                return (404, Data())
            }
        }
        let model = AppModel(
            client: IOSAPIClient(transport: transport),
            tokens: tokens,
            store: store
        )
        await model.onLaunch()
        XCTAssertEqual(model.phase, .paired)

        model.forgetDevice()

        XCTAssertEqual(model.phase, .pairing)
        XCTAssertNil(tokens.token)
        XCTAssertNil(store.device)
        XCTAssertEqual(store.serverURL, "http://127.0.0.1:8000")
        XCTAssertNil(model.today)
        XCTAssertNil(model.pairingError)
    }

    // MARK: - Relayed watch execution

    private func cachedPlan(expiresAt: String = "2099-01-01T00:00:00Z") -> CachedIssuedPlan {
        CachedIssuedPlan(
            issuedPlanId: "plan-1",
            executionId: "exec-1",
            forDate: "2026-11-25",
            sessionType: "squat",
            expiresAt: expiresAt,
            plan: PrescriptionPlan(
                forDate: "2026-11-25",
                sessionType: "squat",
                sessionLabel: "Squat",
                items: [
                    PrescriptionItem(
                        orderIndex: 0,
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
            )
        )
    }

    private func sendRelay(
        _ operation: WatchRelayOperation,
        model: AppModel,
        workoutId: String? = nil,
        issuedPlanId: String? = nil,
        idempotencyKey: String? = nil,
        payload: Data? = nil
    ) async throws -> WatchRelayResponse {
        let request = WatchRelayRequest(
            operation: operation,
            baseURL: "http://127.0.0.1:8000",
            token: "watch-token",
            deviceID: "watch-1",
            workoutId: workoutId,
            issuedPlanId: issuedPlanId,
            idempotencyKey: idempotencyKey,
            payload: payload
        )
        let encoded = try XCTUnwrap(WatchRelayCoding.encodeRequest(request))
        let replied = expectation(description: "relay \(operation.rawValue)")
        var response: WatchRelayResponse?
        model.watchPairing.watchConnectivityDidReceiveMessage(
            ["kind": "relay", "request": encoded]
        ) { dictionary in
            response = (dictionary["response"] as? String)
                .flatMap(WatchRelayCoding.decodeResponse)
            replied.fulfill()
        }
        await fulfillment(of: [replied], timeout: 5)
        let value = try XCTUnwrap(response)
        XCTAssertTrue(value.ok)
        return value
    }

    func testPlanStateNoneClearsTheCachedPlan() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PairedStore(defaults: defaults)
        let captureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-model-plan-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: captureURL) }
        let capture = OfflineCaptureStore(fileURL: captureURL)
        _ = try capture.setCachedPlan(cachedPlan())
        let model = AppModel(
            client: IOSAPIClient(transport: StubTransport { _ in (500, Data()) }),
            tokens: InMemoryTokenStore(),
            store: store,
            offlineStore: capture
        )
        guard case .issued = model.prescriptionState else {
            return XCTFail("the cached plan should be previewable at launch")
        }

        model.applyPlanState(.none)

        guard case .idle = model.prescriptionState else {
            return XCTFail("a consumed plan must not stay startable")
        }
        XCTAssertNil(try capture.load().cachedPlan)
    }

    func testRelayedStartAndFinishClearThePhonePlan() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PairedStore(defaults: defaults)
        store.serverURL = "http://127.0.0.1:8000"
        store.homeServerURL = "http://127.0.0.1:8000"
        store.device = PairingDevice(deviceID: "device-1", label: "iPhone")
        let captureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-model-relay-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: captureURL) }
        let capture = OfflineCaptureStore(fileURL: captureURL)
        _ = try capture.setCachedPlan(cachedPlan())
        let connectivity = RecordingWatchConnectivity()
        var finished = false
        let transport = StubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrapPhase2.utf8))
            case "/api/ios/v1/today":
                return (200, Data(Fixtures.today.utf8))
            case "/api/ios/v1/plans/current":
                return finished
                    ? (200, Data(#"{"status":"none"}"#.utf8))
                    : (200, Data(Fixtures.plansReady.utf8))
            case "/api/ios/v1/workouts":
                return (200, Data(Fixtures.workoutInProgress.utf8))
            case "/api/ios/v1/workouts/workout-1/complete":
                return (200, Data(Fixtures.workoutCompleted.utf8))
            case "/api/ios/v1/history":
                return (200, Data(Fixtures.history.utf8))
            default:
                return (404, Data())
            }
        }
        let model = AppModel(
            client: IOSAPIClient(transport: transport),
            tokens: InMemoryTokenStore(token: "token-abc"),
            store: store,
            offlineStore: capture,
            watchConnectivity: connectivity
        )
        await model.onLaunch()
        guard case .issued = model.prescriptionState else {
            return XCTFail("the ready plan should be previewable")
        }

        _ = try await sendRelay(
            .start,
            model: model,
            issuedPlanId: "plan-1",
            idempotencyKey: "start-1"
        )
        XCTAssertEqual(model.activeWorkout?.workoutId, "workout-1")
        guard case .idle = model.prescriptionState else {
            return XCTFail("the started plan must leave the start surface")
        }
        XCTAssertNil(try capture.load().cachedPlan)

        finished = true
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let finishBody = CompleteWorkoutRequest(
            sessionRpe: 7,
            notRecorded: false,
            durationMin: nil,
            notes: nil,
            endedAt: "2026-11-07T17:00:00+00:00"
        )
        _ = try await sendRelay(
            .finish,
            model: model,
            workoutId: "workout-1",
            idempotencyKey: "finish-1",
            payload: try encoder.encode(finishBody)
        )
        XCTAssertNil(model.activeWorkout)
        guard case .idle = model.prescriptionState else {
            return XCTFail("a finished watch session must not leave a plan")
        }
        XCTAssertNil(try capture.load().cachedPlan)
    }
}

@MainActor
private final class RecordingWatchConnectivity: WatchConnectivitySession {
    weak var delegate: WatchConnectivitySessionDelegate?
    var isSupported = true
    var isPaired = true
    var isWatchAppInstalled = true
    var isReachable = true
    var activationState: WCSessionActivationState = .activated
    var receivedApplicationContext: [String: Any] = [:]
    private(set) var updates: [[String: Any]] = []
    private(set) var userInfos: [[String: Any]] = []
    private(set) var fileTransfers: [(URL, [String: Any])] = []

    func activate() {}
    func updateApplicationContext(_ context: [String: Any]) throws {
        updates.append(context)
    }
    func transferUserInfo(_ userInfo: [String: Any]) {
        userInfos.append(userInfo)
    }

    func transferFile(_ fileURL: URL, metadata: [String: Any]) {
        fileTransfers.append((fileURL, metadata))
    }

    func sendMessage(
        _ message: [String: Any],
        replyHandler: (([String: Any]) -> Void)?,
        errorHandler: ((Error) -> Void)?
    ) {
        replyHandler?([
            "kind": "spike_reply",
            "request_id": message["request_id"] as? String ?? "",
        ])
    }
}

    @MainActor
    private func watchTransport() -> StubTransport {
        StubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/pair":
                return (200, Data(Fixtures.pair.utf8))
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrap.utf8))
            case "/api/ios/v1/today":
                return (200, Data(Fixtures.today.utf8))
            case "/api/ios/v1/devices/watch":
                return (201, Data("{\n  \"device\": {\n    \"device_id\": \"watch-1\",\n    \"label\": \"Apple Watch\",\n    \"kind\": \"watch\",\n    \"parent_device_id\": \"device-1\",\n    \"credential_epoch\": 1\n  },\n  \"token\": \"watch-token\",\n  \"created_at\": \"2026-11-10T20:00:00+00:00\",\n  \"replaced_device_id\": null\n}".utf8))
            default:
                return (404, Data())
            }
        }
    }

    @MainActor
    private func preparePhonePairing(_ model: AppModel) {
        model.serverURLText = "http://127.0.0.1:8000/"
        model.pairingCodeText = "1234 5678"
        model.pairingLabelText = "Gym iPhone"
    }

@MainActor
private func executionChangeModel(
    transport: HTTPTransport,
    journal: MutationJournal? = nil,
    connectivity: WatchConnectivitySession? = nil
) -> (AppModel, String) {
    let suite = "com.georgesdibpersonalteam.StrengthApp.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let store = PairedStore(defaults: defaults)
    store.serverURL = "http://127.0.0.1:8000"
    store.device = PairingDevice(deviceID: "device-1", label: "iPhone")
    let tokens = InMemoryTokenStore(token: "token-abc")
    let capture = OfflineCaptureStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("execution-change-capture-\(UUID().uuidString).json"))
    let model = AppModel(
        client: IOSAPIClient(transport: transport, journal: journal),
        tokens: tokens,
        store: store,
        offlineStore: capture,
        watchConnectivity: connectivity
    )
    return (model, suite)
}

private let executionChangeResponse = #"{"execution":{"workout_id":"workout-1","watermark":1,"substitutions":[{"event_id":1,"kind":"substitution","plan_item_index":0,"exercise_id":"bench_press","reps_low":3,"reps_high":5,"rir_target":2,"prefill_load_kg":null}],"additions":[]}}"#

private func executionChangeToday(staleSet: Bool = false) -> String {
    var workout = Fixtures.watchOwnedWorkout.replacingOccurrences(
        of: "\"status\": \"in_progress\",",
        with: "\"status\": \"in_progress\", \"plan_revision\": 1,"
    )
    if staleSet {
        workout = workout.replacingOccurrences(
            of: "\"sets\": [],",
            with: "\"sets\": [{\"set_id\": 1, \"exercise_id\": \"competition_squat\", \"set_index\": 1, \"load_kg\": 140.0, \"reps\": 3, \"rir\": 2, \"source\": \"device\"}],"
        )
    }
    return #"{"date":"2026-11-07","readiness":null,"readiness_score":null,"active_workout":"# + workout + "}"
}

private func pendingExecutionChange() -> PendingMutation {
    PendingMutation(
        operationId: "change-1",
        deviceId: "device-1",
        serverURL: "http://127.0.0.1:8000",
        kind: .executionChange,
        targetId: "workout-1",
        path: "api/ios/v1/workouts/workout-1/execution",
        bodyData: Data(#"{"event_id":"change-1","change":"substitution","plan_item_index":0,"exercise_id":"bench_press","prefill_requested":false}"#.utf8),
        createdAt: Date(),
        state: .pending
    )
}
