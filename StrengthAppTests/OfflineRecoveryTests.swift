import XCTest

@testable import StrengthApp
import StrengthCore

@MainActor
final class OfflineRecoveryTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "com.georgesdibpersonalteam.StrengthApp.offline-recovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func makeStore() -> (OfflineCaptureStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-recovery-\(UUID().uuidString).json")
        return (OfflineCaptureStore(fileURL: url), url)
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
            sets: [],
            forms: [],
            elapsedSeconds: 0,
            sessionRpe: nil,
            startedAt: "2026-11-08T10:00:00Z"
        )
    }

    private func operation() -> OfflineOperation {
        OfflineOperation(
            operationId: "op-add",
            workoutId: "workout-1",
            body: .addSet(
                AddSetRequest(
                    exerciseId: "competition_squat",
                    loadKg: 140,
                    reps: 3,
                    rir: 2,
                    velocityMps: nil,
                    setIndex: 1,
                    planItemIndex: 1
                )
            ),
            createdAt: Date(),
            localSetId: -1
        )
    }

    private func makeModel(
        captureStore: OfflineCaptureStore,
        pairedStore: PairedStore,
        transport: HTTPTransport? = nil,
        tokens: TokenStoring = InMemoryTokenStore()
    ) -> AppModel {
        let transport = transport ?? StubTransport { _ in (500, Data()) }
        return AppModel(
            client: IOSAPIClient(transport: transport),
            tokens: tokens,
            store: pairedStore,
            offlineStore: captureStore
        )
    }

    func testValidEmptyCaptureLoadsAsSuccess() {
        let (captureStore, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = makeModel(
            captureStore: captureStore,
            pairedStore: PairedStore(defaults: defaults)
        )

        XCTAssertNil(model.offlineRecoveryError)
        XCTAssertNotNil(model.offlineCapture)
        XCTAssertNil(model.activeWorkout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCaptureWithActiveWorkoutAndPendingOperationsLoads() throws {
        let (captureStore, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try captureStore.setActiveWorkout(workout())
        _ = try captureStore.record(operation())
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = makeModel(
            captureStore: captureStore,
            pairedStore: PairedStore(defaults: defaults)
        )

        XCTAssertNil(model.offlineRecoveryError)
        XCTAssertEqual(model.activeWorkout?.workoutId, "workout-1")
        XCTAssertEqual(model.pendingOfflineOperations.count, 1)
    }

    func testClearingRecoveryPersistsNilAndPreservesPendingOperations() throws {
        let (captureStore, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try captureStore.setActiveWorkout(workout())
        _ = try captureStore.record(operation())
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = makeModel(
            captureStore: captureStore,
            pairedStore: PairedStore(defaults: defaults)
        )
        XCTAssertNotNil(model.activeWorkout)

        model.clearWorkoutRecovery()

        XCTAssertNil(model.activeWorkout)
        let persisted = try captureStore.load()
        XCTAssertNil(persisted.activeWorkout)
        XCTAssertEqual(persisted.operations.count, 1)

        let reloaded = makeModel(
            captureStore: captureStore,
            pairedStore: PairedStore(defaults: defaults)
        )
        XCTAssertNil(reloaded.activeWorkout)
        XCTAssertEqual(reloaded.pendingOfflineOperations.count, 1)
    }

    func testNoCaptureAndNoWorkoutDoesNotCreateACapture() {
        let (captureStore, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = makeModel(
            captureStore: captureStore,
            pairedStore: PairedStore(defaults: defaults)
        )
        XCTAssertNotNil(model.offlineCapture)
        XCTAssertNil(model.offlineRecoveryError)
        model.clearWorkoutRecovery()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(model.offlineRecoveryError)
    }

    func testServerActiveWorkoutIsPersistedWhenNoCaptureExists() async throws {
        let (captureStore, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let paired = PairedStore(defaults: defaults)
        paired.serverURL = "http://127.0.0.1:8000"
        paired.homeServerURL = "http://127.0.0.1:8000"
        paired.device = PairingDevice(deviceID: "device-1", label: "iPhone")
        let today = Fixtures.today.replacingOccurrences(
            of: "\"active_workout\": null",
            with: "\"active_workout\": " + Fixtures.workoutInProgress
        )
        let transport = StubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrap.utf8))
            case "/api/ios/v1/today":
                return (200, Data(today.utf8))
            default:
                return (404, Data())
            }
        }
        let model = makeModel(
            captureStore: captureStore,
            pairedStore: paired,
            transport: transport,
            tokens: InMemoryTokenStore(token: "token-abc")
        )

        await model.onLaunch()

        XCTAssertEqual(model.activeWorkout?.workoutId, "workout-1")
        XCTAssertEqual(try captureStore.load().activeWorkout?.workoutId, "workout-1")
    }

    func testExternalCompletionDoesNotResurrectCachedWorkout() async throws {
        let (captureStore, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try captureStore.setActiveWorkout(workout())
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let paired = PairedStore(defaults: defaults)
        paired.serverURL = "http://127.0.0.1:8000"
        paired.homeServerURL = "http://127.0.0.1:8000"
        paired.device = PairingDevice(deviceID: "device-1", label: "iPhone")
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
        let model = makeModel(
            captureStore: captureStore,
            pairedStore: paired,
            transport: transport,
            tokens: InMemoryTokenStore(token: "token-abc")
        )

        await model.onLaunch()

        XCTAssertNil(model.activeWorkout)
        XCTAssertNil(try captureStore.load().activeWorkout)
        guard let issue = model.recoveryIssue,
              case .workoutEndedElsewhere = issue else {
            return XCTFail("expected an externally ended recovery state")
        }
    }

    func testUnsupportedCaptureVersionIsSurfacedAndNotOverwritten() throws {
        let (captureStore, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(OfflineCapture(version: 99))
        try data.write(to: url)
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = makeModel(
            captureStore: captureStore,
            pairedStore: PairedStore(defaults: defaults)
        )
        XCTAssertEqual(model.offlineRecoveryError, .unsupportedVersion(99))
        XCTAssertNil(model.offlineCapture)

        model.clearWorkoutRecovery()
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testExplicitDiscardResolvesUnreadableRecovery() async throws {
        let (captureStore, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{not-json".utf8).write(to: url)
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = makeModel(
            captureStore: captureStore,
            pairedStore: PairedStore(defaults: defaults)
        )
        XCTAssertNotNil(model.offlineRecoveryError)

        let discarded = await model.discardAllOfflineCapture()

        XCTAssertTrue(discarded)
        XCTAssertNil(model.offlineRecoveryError)
        XCTAssertNotNil(model.offlineCapture)
        XCTAssertNil(try captureStore.load().activeWorkout)
    }

    func testStorageReadFailureIsSurfacedAndRetryRecovers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-recovery-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let captureStore = OfflineCaptureStore(fileURL: directory)
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = makeModel(
            captureStore: captureStore,
            pairedStore: PairedStore(defaults: defaults)
        )
        guard let error = model.offlineRecoveryError,
              case .io = error else {
            return XCTFail("expected an I/O recovery error")
        }

        try FileManager.default.removeItem(at: directory)
        try captureStore.clear()
        XCTAssertTrue(model.retryOfflineRecovery())
        XCTAssertNil(model.offlineRecoveryError)
        XCTAssertNotNil(model.offlineCapture)
    }
}
