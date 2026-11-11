import XCTest
@testable import StrengthApp
import StrengthCore

@MainActor
final class ExecutionTelemetryTests: XCTestCase {
    func testExecutionEventPayloadEncodingIsClosedAndTimestamped() throws {
        let event = ExecutionEvent(
            eventId: "11111111-1111-4111-8111-111111111111",
            eventType: .setStarted,
            occurredAt: "2026-11-09T12:00:00.000Z",
            planItemIndex: 2,
            localSetId: "local-set",
            payload: ["set_index": .number(1)]
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(ExecutionEventsRequest(events: [event]))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["event_type"] as? String, "set_started")
        XCTAssertEqual(events[0]["local_set_id"] as? String, "local-set")
        XCTAssertEqual(events[0]["occurred_at"] as? String, "2026-11-09T12:00:00.000Z")
    }

    func testExecutionEventsJoinTheExistingOfflineOutboxInBatches() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("execution-outbox-\(UUID().uuidString).json")
        let store = OfflineCaptureStore(fileURL: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let workout = try decoder.decode(
            WorkoutDetail.self, from: Data(Fixtures.workoutWithSet.utf8)
        )
        let first = ExecutionEvent(eventType: .setStarted, localSetId: "set-a")
        let second = ExecutionEvent(eventType: .setCompleted, localSetId: "set-a")
        let capture = try store.appendExecutionEvents(
            workoutId: workout.workoutId,
            events: [first],
            activeWorkout: workout
        )
        XCTAssertEqual(capture.operations.count, 1)
        let appended = try store.appendExecutionEvents(
            workoutId: workout.workoutId,
            events: [second],
            activeWorkout: workout
        )
        XCTAssertEqual(appended.operations.count, 1)
        guard case .executionEvents(let events) = appended.operations[0].body else {
            return XCTFail("expected execution event batch")
        }
        XCTAssertEqual(events.map(\.eventId), [first.eventId, second.eventId])
        XCTAssertEqual(appended.operations[0].kind, .executionEvents)
    }

    @MainActor
    func testRestTimerPreservesPrescribedActualAndExtension() {
        let timer = RestTimerModel()
        timer.start(seconds: 90)
        timer.extend(by: 15)
        let result = timer.finish(outcome: "skipped")
        XCTAssertEqual(result?.prescribedSeconds, 90)
        XCTAssertEqual(result?.addedSeconds, 15)
        XCTAssertEqual(result?.outcome, "skipped")
        XCTAssertNotNil(result?.startedAt)
        XCTAssertEqual(timer.startedAt, nil)
    }

    @MainActor
    func testRestTimerAutoCompletesOnceAndClearsState() {
        let timer = RestTimerModel()
        var results: [RestTimerResult] = []
        timer.onFinish = { results.append($0) }
        timer.start(seconds: 1)
        timer.refresh(now: Date().addingTimeInterval(2))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.outcome, "completed")
        XCTAssertNil(timer.startedAt)
        XCTAssertNil(timer.endDate)
    }

    func testExecutionAnalyticsDecodesServerShape() throws {
        let json = """
        {"workout_id":"w","status":"completed",
         "started_at":"2026-11-09T12:00:00.000Z","ended_at":"2026-11-09T12:10:00.000Z",
         "total_elapsed_s":600,
         "events":[{"event_id":"e1","event_type":"set_started",
           "occurred_at":"2026-11-09T12:00:01.000Z","plan_item_index":0,
           "set_id":1,"local_set_id":null,"payload":{}}],
         "sets":[{"set_id":1,"local_set_id":"local","plan_item_index":0,
           "started_at":"2026-11-09T12:00:01.000Z",
           "completed_at":"2026-11-09T12:00:31.000Z","duration_s":30}],
         "rests":[{"started_at":"2026-11-09T12:00:32.000Z",
           "ended_at":"2026-11-09T12:01:02.000Z","prescribed_rest_s":60,
           "actual_rest_s":30,"outcome":"completed","deviation_s":-30,
           "deviation_pct":-50,"plan_item_index":0}],
         "exercises":[],
         "summary":{"active_lifting_s":30,"recorded_recovery_s":30,
           "exercise_transition_s":0,"unclassified_s":540,"total_elapsed_s":600},
         "data_quality":{"event_count":1,"sets_with_duration":1,
           "rests_with_actual":1,"rests_without_prescribed":0,"workout_has_end":true}}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(
            ExecutionAnalyticsResponse.self, from: Data(json.utf8)
        )
        XCTAssertEqual(response.sets.first?.durationS, 30)
        XCTAssertEqual(response.rests.first?.deviationS, -30)
        XCTAssertEqual(response.summary.activeLiftingS, 30)
    }

    func testExecutionEventsAPIAcceptsBatchResponse() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(
                request.url?.path,
                "/api/ios/v1/workouts/workout-1/execution-events"
            )
            XCTAssertEqual(request.httpMethod, "POST")
            let response = """
            {"workout_id":"workout-1","accepted":["e1"],"duplicates":[],
             "received_at":"2026-11-09T12:00:01.000Z"}
            """
            return (200, Data(response.utf8))
        }
        let client = IOSAPIClient(transport: transport)
        let response = try await client.submitExecutionEvents(
            workoutId: "workout-1",
            events: [ExecutionEvent(eventId: "e1", eventType: .setStarted)],
            session: IOSSession(
                baseURL: URL(string: "http://127.0.0.1:8000")!,
                token: "token",
                deviceID: "device"
            ),
            idempotencyKey: "batch-key"
        )
        XCTAssertEqual(response.accepted, ["e1"])
        XCTAssertEqual(transport.requests.count, 1)
    }
}
