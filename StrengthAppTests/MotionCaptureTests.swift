import XCTest
@testable import StrengthCore

final class MotionCaptureTests: XCTestCase {
    private func samples(count: Int, hz: Double, start: Double = 0) -> [MotionSample] {
        (0..<count).map { index in
            MotionSample(
                t: start + Double(index) / hz,
                ax: 0.1, ay: 0.0, az: 0.0,
                rx: 0.0, ry: 0.0, rz: 0.0,
                gx: 0.0, gy: 0.0, gz: -1.0
            )
        }
    }

    func testGapReportAcceptsAContinuousCapture() {
        let report = MotionGapReport.measure(samples(count: 300, hz: 100), nominalRateHz: 100)
        XCTAssertEqual(report.actualSamples, 300)
        XCTAssertEqual(report.gaps, 0)
        XCTAssertTrue(report.isHealthy)
        XCTAssertLessThan(report.droppedFraction, 0.01)
    }

    func testGapReportDetectsAStall() {
        var trace = samples(count: 50, hz: 100)
        trace += samples(count: 50, hz: 100, start: 1.0) // 0.5 s of nothing at 0.49 s
        let report = MotionGapReport.measure(trace, nominalRateHz: 100)
        XCTAssertEqual(report.gaps, 1)
        XCTAssertGreaterThan(report.maxGapSeconds, 0.4)
        XCTAssertFalse(report.isHealthy)
        XCTAssertGreaterThan(report.droppedFraction, 0.2)
    }

    func testGapReportOfAnEmptyCaptureIsNeverHealthy() {
        let report = MotionGapReport.measure([], nominalRateHz: 100)
        XCTAssertEqual(report.actualSamples, 0)
        XCTAssertFalse(report.isHealthy)
    }

    func testRecorderAccumulatesAndResets() {
        let context = MotionCaptureContext(
            workoutId: "w1", exerciseId: "competition_squat", planItemIndex: 0,
            setOrdinal: 2, axis: .vertical
        )
        let recorder = MotionRecorder(context: context, nominalRateHz: 100)
        recorder.append(samples(count: 40, hz: 100))
        recorder.append(samples(count: 20, hz: 100, start: 0.4))
        XCTAssertEqual(recorder.sampleCount, 60)

        let recording = recorder.finish()
        XCTAssertEqual(recording.samples.count, 60)
        XCTAssertEqual(recording.context.setOrdinal, 2)
        XCTAssertEqual(recording.context.axis, .vertical)
        XCTAssertEqual(recording.methodVersion, "tempo/1")
        XCTAssertEqual(recorder.sampleCount, 0)
    }

    func testStoreRoundTripsAndListsNewestFirst() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MotionRecordingStore(directory: root)

        let first = MotionSetRecording(
            context: MotionCaptureContext(
                workoutId: "w1", exerciseId: "bench_press", planItemIndex: 1,
                setOrdinal: 1, axis: .vertical, startedAt: Date(timeIntervalSince1970: 1_000)
            ),
            endedAt: Date(timeIntervalSince1970: 1_100),
            nominalRateHz: 100,
            gap: MotionGapReport.measure(samples(count: 10, hz: 100), nominalRateHz: 100),
            samples: samples(count: 10, hz: 100)
        )
        let second = MotionSetRecording(
            context: MotionCaptureContext(
                workoutId: "w1", exerciseId: "competition_squat", planItemIndex: 0,
                setOrdinal: 2, axis: .vertical, startedAt: Date(timeIntervalSince1970: 2_000)
            ),
            endedAt: Date(timeIntervalSince1970: 2_100),
            nominalRateHz: 100,
            gap: MotionGapReport.measure(samples(count: 10, hz: 100), nominalRateHz: 100),
            samples: samples(count: 10, hz: 100)
        )
        _ = try store.save(first)
        let url = try store.save(second)
        XCTAssertEqual(try store.load(url).context.exerciseId, "competition_squat")
        XCTAssertEqual(store.recordings().count, 2)
        XCTAssertEqual(store.recordings().first?.lastPathComponent, url.lastPathComponent)
    }

    func testRetentionNeverDeletesAnUnexportedRecording() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MotionRecordingStore(directory: root)
        _ = try store.save(recording(startedAt: Date(timeIntervalSince1970: 1_000)))

        // Way past the backstop window, and still the only copy.
        let removed = store.purgeExported(now: Date(timeIntervalSince1970: 10_000_000))
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(store.recordings().count, 1)
    }

    func testRetentionRemovesExportedRecordingsAfterTheBackstop() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MotionRecordingStore(directory: root)
        let url = try store.save(recording(startedAt: Date(timeIntervalSince1970: 1_000)))
        let oldExport = Date(timeIntervalSinceNow: -40 * 86_400)
        try store.markExported(url, at: oldExport)

        let removed = store.purgeExported()
        XCTAssertEqual(removed.count, 1)
        XCTAssertTrue(store.recordings().isEmpty)
    }

    func testRetentionKeepsARecentExport() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MotionRecordingStore(directory: root)
        let url = try store.save(recording(startedAt: Date(timeIntervalSince1970: 1_000)))
        try store.markExported(url, at: Date(timeIntervalSinceNow: -2 * 86_400))

        XCTAssertTrue(store.purgeExported().isEmpty)
        XCTAssertEqual(store.recordings().count, 1)
    }

    func testExportStateSurvivesANewStoreInstance() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = MotionRecordingStore(directory: root)
        let url = try first.save(recording(startedAt: Date(timeIntervalSince1970: 1_000)))
        try first.markExported(url, at: Date(timeIntervalSince1970: 2_000))

        let second = MotionRecordingStore(directory: root)
        XCTAssertNotNil(second.exportedAt(url))
    }

    private func recording(startedAt: Date) -> MotionSetRecording {
        MotionSetRecording(
            context: MotionCaptureContext(
                workoutId: "w1", exerciseId: "bench_press", planItemIndex: 0,
                setOrdinal: 1, axis: .vertical, startedAt: startedAt
            ),
            endedAt: startedAt.addingTimeInterval(2),
            nominalRateHz: 100,
            gap: MotionGapReport.measure(samples(count: 10, hz: 100), nominalRateHz: 100),
            samples: samples(count: 10, hz: 100)
        )
    }
}
