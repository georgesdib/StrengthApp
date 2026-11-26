import XCTest

@testable import StrengthApp
import StrengthCore

final class OfflineLedgerMergeTests: XCTestCase {
    private var fileURL: URL!
    private var clock: Date!
    private var store: OfflineCaptureStore!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-ledger-\(UUID().uuidString).json")
        clock = Date(timeIntervalSince1970: 1_800_000_000)
        store = OfflineCaptureStore(fileURL: fileURL, now: { [unowned self] in self.clock })
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func workout() -> WorkoutDetail {
        WorkoutDetail(
            workoutId: "exec-1",
            prescriptionId: "plan-1",
            forDate: "2026-11-23",
            sessionType: "squat",
            status: "in_progress",
            plan: PrescriptionPlan(
                forDate: "2026-11-23",
                sessionType: "squat",
                sessionLabel: "Squat",
                items: [
                    PrescriptionItem(
                        orderIndex: 0, exerciseId: "competition_squat", sets: 3,
                        repsLow: 5, repsHigh: 5, loadKg: 140, loadBasis: "external",
                        rirTarget: 2, effortModel: "rir", refs: nil, restS: 180,
                        essential: true
                    )
                ],
                warnings: nil, issues: nil
            ),
            sets: [], forms: [], elapsedSeconds: 0, sessionRpe: nil,
            startedAt: "2026-11-23T10:00:00Z"
        )
    }

    private func operation(
        id: String = "op-add",
        localSetId: Int = -1,
        createdAt: Date? = nil
    ) -> OfflineOperation {
        OfflineOperation(
            operationId: id,
            workoutId: "exec-1",
            body: .addSet(AddSetRequest(
                exerciseId: "competition_squat", loadKg: 140, reps: 3, rir: 2,
                velocityMps: nil, setIndex: 1, planItemIndex: 0
            )),
            createdAt: createdAt ?? clock,
            localSetId: localSetId,
            deviceId: "watch-1"
        )
    }

    func testVersionOneCaptureMigratesInPlace() throws {
        _ = try store.setActiveWorkout(workout())
        _ = try store.record(operation())
        // Encode the current file, then strip the ledger-only fields and set version 1: the
        // exact shape an app updated mid-workout finds on disk.
        let data = try Data(contentsOf: fileURL)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["version"] = 1
        if var operations = object["operations"] as? [[String: Any]], !operations.isEmpty {
            for key in ["deviceId", "deviceSeq", "createdAtLocal", "clockOffsetSeconds",
                        "planWatermark", "ackState"] {
                operations[0].removeValue(forKey: key)
            }
            object["operations"] = operations
        }
        try JSONSerialization.data(withJSONObject: object).write(to: fileURL)

        let loaded = try store.load()
        XCTAssertEqual(loaded.version, OfflineCapture.currentVersion)
        let op = try XCTUnwrap(loaded.operations.first)
        XCTAssertEqual(op.operationId, "op-add")
        XCTAssertEqual(op.localSetId, -1)
        XCTAssertEqual(op.createdAtLocal, op.createdAt)
        XCTAssertEqual(op.deviceSeq, 0)
        XCTAssertEqual(op.ackState, .pending)
        // The migrated file on disk is version 2.
        let migrated = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL))
            as? [String: Any]
        XCTAssertEqual(migrated?["version"] as? Int, 2)
    }

    func testLedgerEntriesAreNotAgedOutBeforeAcknowledgement() throws {
        _ = try store.setActiveWorkout(workout())
        let veryOld = OfflineOperation(
            operationId: "op-old",
            workoutId: "exec-1",
            body: .rateForm(FormRatingRequest(
                exerciseId: "competition_squat", rating: 4, note: nil
            )),
            createdAt: clock.addingTimeInterval(-365 * 24 * 60 * 60),
            deviceId: "phone-1"
        )
        _ = try store.record(veryOld)
        let retained = try store.load().operations
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained.first?.state, .pending)
        XCTAssertEqual(retained.first?.ackState, .pending)
        XCTAssertEqual(try store.replayable(now: clock).count, 1)
    }

    func testLedgerProvenanceComesFromTheActiveSession() throws {
        _ = try store.setActiveWorkout(workout())
        _ = try store.setSession(WatchSessionRecord(
            sessionUUID: "session-1",
            deviceId: "watch-1",
            startedAt: clock,
            clockOffsetSeconds: -12,
            execution: ExecutionView(watermark: 4)
        ))
        _ = try store.record(OfflineOperation(
            operationId: "op-provenance",
            workoutId: "exec-1",
            body: .rateForm(FormRatingRequest(
                exerciseId: "competition_squat", rating: 4, note: nil
            )),
            createdAt: clock
        ))
        let entry = try XCTUnwrap(try store.load().operations.first)
        XCTAssertEqual(entry.deviceId, "watch-1")
        XCTAssertEqual(entry.clockOffsetSeconds, -12)
        XCTAssertEqual(entry.planWatermark, 4)
        XCTAssertEqual(entry.createdAtLocal, clock)
        XCTAssertEqual(entry.entryId, "op-provenance")
    }

    func testCollisionRewriteChangesOnlyTheSetIndex() throws {
        _ = try store.setActiveWorkout(workout())
        _ = try store.record(operation(id: "op-collision", localSetId: -7))
        let updated = try store.replaceAddSetIndex(
            operationId: "op-collision",
            setIndex: 9
        )
        guard case .addSet(let body) = updated.operations.first?.body else {
            return XCTFail("expected add-set body")
        }
        XCTAssertEqual(body.setIndex, 9)
        XCTAssertEqual(body.exerciseId, "competition_squat")
        XCTAssertEqual(body.loadKg, 140)
        XCTAssertEqual(body.reps, 3)
        XCTAssertEqual(body.rir, 2)
        XCTAssertEqual(body.planItemIndex, 0)
    }

    func testRewritingACaptureKeepsTheCachedPlan() throws {
        _ = try store.setActiveWorkout(workout())
        let catalogue = LoadCatalogue(
            catalogueVersion: "load-catalogue/v1", asOf: "2026-11-23",
            exercises: ["competition_squat": LoadCatalogueEntry(
                loadSource: "e1rm", baseLoadKg: 163.3, accessoryLoadKg: 140,
                incrementKg: 0.5, bodyweight: false, power: false
            )]
        )
        let cached = CachedIssuedPlan(
            issuedPlanId: "plan-1", executionId: "exec-1", forDate: "2026-11-23",
            sessionType: "squat", expiresAt: "2026-11-23T14:00:00Z",
            plan: try XCTUnwrap(workout().plan), loadCatalogue: catalogue
        )
        _ = try store.setCachedPlan(cached)
        let loaded = try store.load()
        XCTAssertEqual(loaded.cachedPlan?.executionId, "exec-1")
        XCTAssertEqual(loaded.cachedPlan?.loadCatalogue?.version, "load-catalogue/v1")
    }

    func testMergeRenumbersCollisionsInCaptureOrderAndKeepsWarmups() {
        let existing: [(exerciseId: String, setIndex: Int)] = [
            ("competition_squat", 1), ("competition_squat", 2),
            ("bench_press", 1),
        ]
        let incoming = [
            ProvisionalSet(deviceId: "watch-1", localSetId: "a",
                           exerciseId: "competition_squat", setIndex: 2),
            ProvisionalSet(deviceId: "watch-1", localSetId: "b",
                           exerciseId: "competition_squat", setIndex: 3),
            ProvisionalSet(deviceId: "watch-1", localSetId: "c",
                           exerciseId: "competition_squat", setIndex: 1000),
            ProvisionalSet(deviceId: "watch-1", localSetId: "d",
                           exerciseId: "competition_squat", setIndex: 1000),
            ProvisionalSet(deviceId: "watch-1", localSetId: "e",
                           exerciseId: "bench_press", setIndex: 1),
        ]
        let merged = SetMerge.renumber(incoming, existing: existing)
        XCTAssertEqual(merged.map(\.setIndex), [3, 4, 1000, 1001, 2])
        XCTAssertEqual(merged.map(\.localSetId), ["a", "b", "c", "d", "e"])
        XCTAssertTrue(merged.allSatisfy { $0.deviceId == "watch-1" })
    }

    func testMergeNeverRejectsAnEmptyOrZeroIndex() {
        let merged = SetMerge.renumber(
            [ProvisionalSet(deviceId: "watch-1", localSetId: "a",
                            exerciseId: "competition_squat", setIndex: 0)],
            existing: [("competition_squat", 1), ("competition_squat", 2)]
        )
        XCTAssertEqual(merged.first?.setIndex, 3)
    }

    func testLocalSetMapTranslatesOnlyAcknowledgedSets() {
        var map = LocalSetMap()
        XCTAssertEqual(
            map.reference(deviceId: "watch-1", localSetId: "local-1"),
            .localLedger
        )
        map.record(deviceId: "watch-1", localSetId: "local-1", setId: 42)
        XCTAssertEqual(
            map.reference(deviceId: "watch-1", localSetId: "local-1"),
            .server(setId: 42)
        )
        XCTAssertEqual(
            map.reference(deviceId: "phone-1", localSetId: "local-1"),
            .localLedger
        )
    }

    func testPlanCacheFileRoundTripsPlanAndCatalogue() throws {
        let cache = WatchPlanCache(
            issuedPlanId: "plan-1",
            executionId: "exec-1",
            forDate: "2026-11-23",
            sessionType: "squat",
            expiresAt: "2026-11-23T14:00:00Z",
            plan: try XCTUnwrap(workout().plan),
            loadCatalogue: LoadCatalogue(
                catalogueVersion: "load-catalogue/v1", asOf: "2026-11-23"
            ),
            warnings: []
        )
        let data = try JSONEncoder().encode(cache)
        let decoded = try JSONDecoder().decode(WatchPlanCache.self, from: data)
        XCTAssertEqual(decoded.executionId, "exec-1")
        XCTAssertEqual(decoded.summary.executionID, "exec-1")
        XCTAssertEqual(decoded.summary.items.count, 1)
    }
}
