import XCTest

@testable import StrengthApp

@MainActor
final class Phase2ClientTests: XCTestCase {
    private let session = IOSSession(
        baseURL: URL(string: "http://127.0.0.1:8000")!,
        token: "token-abc"
    )

    private func body(_ request: URLRequest) -> [String: Any] {
        guard let data = request.httpBody,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return [:]
        }
        return dictionary
    }

    func testPlanItemChoicesListRepeatedOccurrences() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let plan = try decoder.decode(
            PrescriptionPlan.self,
            from: Data(#"{"items":[{"order_index":0,"exercise_id":"competition_squat","sets":3,"reps_low":5,"reps_high":5,"load_kg":140,"rir_target":2},{"order_index":1,"exercise_id":"bench_press","sets":4,"reps_low":5,"reps_high":5,"load_kg":100,"rir_target":2},{"order_index":2,"exercise_id":"competition_squat","sets":2,"reps_low":3,"reps_high":3,"load_kg":120,"rir_target":3}]}"#.utf8)
        )
        let choices = plan.choices(for: "competition_squat")
        XCTAssertEqual(choices.count, 2)
        XCTAssertEqual(choices.map(\.index), [0, 2])
        XCTAssertEqual(choices[0].label, "Item 1 · 3 sets · 5 · 140.0 kg · RIR 2")
        XCTAssertEqual(choices[1].label, "Item 3 · 2 sets · 3 · 120.0 kg · RIR 3")
        XCTAssertNil(plan.uniquePlanItemIndex(for: "competition_squat"))
        XCTAssertEqual(plan.resolvedPlanItemIndex(for: "competition_squat", selected: 2), 2)
        XCTAssertNil(plan.resolvedPlanItemIndex(for: "competition_squat", selected: nil))
        XCTAssertNil(plan.resolvedPlanItemIndex(for: "competition_squat", selected: 99))
        XCTAssertEqual(plan.choices(for: "bench_press").count, 1)
        XCTAssertEqual(plan.uniquePlanItemIndex(for: "bench_press"), 1)
        XCTAssertEqual(plan.resolvedPlanItemIndex(for: "bench_press", selected: nil), 1)
    }

    func testOperationKeyReusesOnlyTheExactBody() {
        var token = OperationKey<AddSetRequest>()
        let first = AddSetRequest(
            exerciseId: "competition_squat", loadKg: 140, reps: 3,
            rir: 2, velocityMps: 0.62, setIndex: 1, planItemIndex: 0
        )
        let key = token.use(first)
        XCTAssertEqual(token.use(first), key)

        let changed = AddSetRequest(
            exerciseId: "competition_squat", loadKg: 140, reps: 4,
            rir: 2, velocityMps: 0.62, setIndex: 1, planItemIndex: 0
        )
        let changedKey = token.use(changed)
        XCTAssertNotEqual(changedKey, key)

        token.acknowledged()
        XCTAssertNil(token.body)
        XCTAssertNotEqual(token.use(changed), changedKey)
    }

    func testPlanItemAttributionOnlyUsesAUniqueExercise() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let repeated = try decoder.decode(
            PrescriptionPlan.self,
            from: Data(#"{"items":[{"order_index":0,"exercise_id":"competition_squat"},{"order_index":1,"exercise_id":"bench_press"},{"order_index":2,"exercise_id":"competition_squat"}]}"#.utf8)
        )
        XCTAssertNil(repeated.uniquePlanItemIndex(for: "competition_squat"))
        XCTAssertEqual(repeated.uniquePlanItemIndex(for: "bench_press"), 1)
        XCTAssertNil(repeated.uniquePlanItemIndex(for: "deadlift"))

        let unique = try decoder.decode(
            PrescriptionPlan.self,
            from: Data(#"{"items":[{"order_index":0,"exercise_id":"competition_squat"},{"order_index":1,"exercise_id":"bench_press"}]}"#.utf8)
        )
        XCTAssertEqual(unique.uniquePlanItemIndex(for: "competition_squat"), 0)
        XCTAssertEqual(unique.uniquePlanItemIndex(for: "bench_press"), 1)
    }
    func testJournaledMutationReplaysWithOriginalKeyAndBody() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("client-journal-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = MutationJournal(fileURL: url)
        let transport = StubTransport { _ in
            throw URLError(.timedOut)
        }
        let client = IOSAPIClient(transport: transport, journal: journal)
        let session = IOSSession(
            baseURL: URL(string: "http://127.0.0.1:8000")!,
            token: "token-abc",
            deviceID: "device-1"
        )
        let body = AddSetRequest(
            exerciseId: "competition_squat", loadKg: 140, reps: 3,
            rir: 2, velocityMps: 0.62, setIndex: 1, planItemIndex: 0
        )
        do {
            _ = try await client.addSet(
                workoutId: "workout-1", body: body,
                session: session, idempotencyKey: "operation-1"
            )
            XCTFail("expected a transport failure")
        } catch {
            // The journal must retain the attempted operation.
        }
        let entries = journal.all(
            for: "device-1", serverURL: "http://127.0.0.1:8000"
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].kind, .addSet)
        XCTAssertEqual(entries[0].operationId, "operation-1")

        transport.handler = { _ in
            (200, Data(Fixtures.workoutWithSet.utf8))
        }
        let replayed: WorkoutDetail = try await client.replay(
            entries[0], session: session
        )
        XCTAssertEqual(replayed.workoutId, "workout-1")
        XCTAssertEqual(replayed.sets?.count, 1)
        XCTAssertTrue(
            journal.all(for: "device-1", serverURL: "http://127.0.0.1:8000").isEmpty
        )
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests[0].httpBody, transport.requests[1].httpBody)
        XCTAssertEqual(
            transport.requests[0].value(forHTTPHeaderField: "Idempotency-Key"),
            "operation-1"
        )
        XCTAssertEqual(
            transport.requests[1].value(forHTTPHeaderField: "Idempotency-Key"),
            "operation-1"
        )
    }

    func testReadinessWriteUsesSnakeCaseAndIdempotency() async throws {
        let transport = StubTransport { _ in
            (200, Data(Fixtures.readinessWrite.utf8))
        }
        let client = IOSAPIClient(transport: transport)
        let result = try await client.writeReadiness(
            ReadinessWriteRequest(values: ["sleep": 4], note: "felt good"),
            session: session,
            idempotencyKey: "key-readiness"
        )
        XCTAssertEqual(result.score?.status, "ready")
        XCTAssertEqual(result.score?.score, 0.82)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/ios/v1/readiness")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "key-readiness")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-abc")
        let json = body(request)
        XCTAssertEqual(json["values"] as? [String: Double], ["sleep": 4])
        XCTAssertEqual(json["note"] as? String, "felt good")
    }

    func testIssuePrescriptionSendsAcknowledgementAndSettings() async throws {
        let transport = StubTransport { request in
            if request.url?.path == "/api/ios/v1/plans/current" {
                return (200, Data(Fixtures.plansReady.utf8))
            }
            return (202, Data(Fixtures.planAck.utf8))
        }
        let client = IOSAPIClient(transport: transport)
        let ack = try await client.issuePrescription(
            IssuePrescriptionRequest(
                readinessAck: true,
                confirmations: ["deload": false],
                settings: PlanSettings(sessionType: "squat", minimumSession: true)
            ),
            session: session,
            idempotencyKey: "key-issue"
        )
        XCTAssertEqual(ack.issuedPlanId, "plan-1")
        XCTAssertEqual(ack.status, "queued")

        let issueRequest = try XCTUnwrap(
            transport.requests.first { $0.url?.path == "/api/ios/v1/prescriptions" }
        )
        XCTAssertEqual(issueRequest.value(forHTTPHeaderField: "Idempotency-Key"), "key-issue")
        let json = body(issueRequest)
        XCTAssertEqual(json["readiness_ack"] as? Bool, true)
        let confirmations = json["confirmations"] as? [String: Bool]
        XCTAssertEqual(confirmations?["deload"], false)
        let settings = json["settings"] as? [String: Any]
        XCTAssertEqual(settings?["session_type"] as? String, "squat")
        XCTAssertEqual(settings?["minimum_session"] as? Bool, true)
        XCTAssertNil(json["plan"])

        // The plan itself comes from the authoritative read, never from the POST response.
        let state = try await client.planState(session: session)
        XCTAssertEqual(state.status, "ready")
        XCTAssertEqual(state.issuedPlan?.plan.items.first?.exerciseId, "competition_squat")
        XCTAssertEqual(state.issuedPlan?.plan.items.first?.loadKg, 140)
        let readRequest = try XCTUnwrap(
            transport.requests.first { $0.url?.path == "/api/ios/v1/plans/current" }
        )
        XCTAssertNil(readRequest.value(forHTTPHeaderField: "Idempotency-Key"))
    }

    func testStartAndAddSetSendSnakeCaseBodies() async throws {
        let transport = StubTransport { request in
            if request.url?.path.hasSuffix("/sets") == true {
                return (200, Data(Fixtures.workoutWithSet.utf8))
            }
            return (200, Data(Fixtures.workoutInProgress.utf8))
        }
        let client = IOSAPIClient(transport: transport)
        let started = try await client.startWorkout(
            issuedPlanId: "plan-1",
            session: session,
            idempotencyKey: "key-start"
        )
        XCTAssertEqual(started.workoutId, "workout-1")
        XCTAssertEqual(started.status, "in_progress")
        let startBody = body(try XCTUnwrap(transport.requests.first))
        XCTAssertEqual(startBody["issued_plan_id"] as? String, "plan-1")

        let updated = try await client.addSet(
            workoutId: "workout-1",
            body: AddSetRequest(
                exerciseId: "competition_squat",
                loadKg: 140,
                reps: 3,
                rir: 2,
                velocityMps: 0.62,
                setIndex: 1,
                planItemIndex: 0
            ),
            session: session,
            idempotencyKey: "key-set"
        )
        XCTAssertEqual(updated.sets?.count, 1)
        XCTAssertEqual(updated.sets?.first?.velocity, 0.62)
        let setRequest = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(setRequest.url?.path, "/api/ios/v1/workouts/workout-1/sets")
        XCTAssertEqual(setRequest.value(forHTTPHeaderField: "Idempotency-Key"), "key-set")
        let setBody = body(setRequest)
        XCTAssertEqual(setBody["exercise_id"] as? String, "competition_squat")
        XCTAssertEqual(setBody["velocity_mps"] as? Double, 0.62)
        XCTAssertEqual(setBody["set_index"] as? Int, 1)
        XCTAssertEqual(setBody["plan_item_index"] as? Int, 0)
    }

    func testFormCompleteAndAbandonBodies() async throws {
        let transport = StubTransport { request in
            if request.url?.path.hasSuffix("/form") == true {
                return (200, Data(Fixtures.workoutWithSet.utf8))
            }
            return (200, Data(Fixtures.workoutCompleted.utf8))
        }
        let client = IOSAPIClient(transport: transport)
        _ = try await client.rateForm(
            workoutId: "workout-1",
            body: FormRatingRequest(
                exerciseId: "competition_squat", rating: 4, note: nil
            ),
            session: session,
            idempotencyKey: "key-form"
        )
        let formBody = body(try XCTUnwrap(transport.requests.last))
        XCTAssertEqual(formBody["exercise_id"] as? String, "competition_squat")
        XCTAssertEqual(formBody["rating"] as? Int, 4)

        let completed = try await client.completeWorkout(
            workoutId: "workout-1",
            body: CompleteWorkoutRequest(
                sessionRpe: 7, notRecorded: false, durationMin: 45, notes: "good"
            ),
            session: session,
            idempotencyKey: "key-complete"
        )
        XCTAssertEqual(completed.status, "completed")
        XCTAssertEqual(completed.sessionRpe, 7)
        let completeBody = body(try XCTUnwrap(transport.requests.last))
        XCTAssertEqual(completeBody["session_rpe"] as? Double, 7)
        XCTAssertEqual(completeBody["not_recorded"] as? Bool, false)
        XCTAssertEqual(completeBody["duration_min"] as? Double, 45)
        XCTAssertEqual(completeBody["notes"] as? String, "good")

        _ = try await client.abandonWorkout(
            workoutId: "workout-1",
            session: session,
            idempotencyKey: "key-abandon"
        )
        let abandonRequest = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(abandonRequest.url?.path, "/api/ios/v1/workouts/workout-1/abandon")
        XCTAssertEqual(body(abandonRequest).count, 0)
    }

    func testProgressDecodesAndSendsWindow() async throws {
        let transport = StubTransport { _ in
            (200, Data(Fixtures.progress.utf8))
        }
        let client = IOSAPIClient(transport: transport)
        let progress = try await client.progress(weeks: 8, session: session)
        XCTAssertEqual(progress.coverage.sessions, 2)
        XCTAssertEqual(progress.volume.first?.pattern, "squat")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/api/ios/v1/progress")
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        XCTAssertTrue(components?.queryItems?.contains(
            URLQueryItem(name: "weeks", value: "8")
        ) == true)
    }

    func testReadinessConflictCarriesCodeAndDetails() async throws {
        let transport = StubTransport { _ in
            (409, Data(Fixtures.serverError.utf8))
        }
        let client = IOSAPIClient(transport: transport)
        do {
            _ = try await client.issuePrescription(
                IssuePrescriptionRequest(
                    readinessAck: false, confirmations: nil, settings: nil
                ),
                session: session,
                idempotencyKey: "key-conflict"
            )
            XCTFail("expected a conflict")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "readiness_required")
            XCTAssertEqual(error.details?["status"]?.stringValue, "unknown")
            XCTAssertEqual(error.details?["can_acknowledge"]?.boolValue, true)
        }
    }

    func testMutationsDoNotRetryTransportFailures() async throws {
        let transport = StubTransport { _ in
            throw URLError(.timedOut)
        }
        let client = IOSAPIClient(transport: transport)
        do {
            _ = try await client.addSet(
                workoutId: "workout-1",
                body: AddSetRequest(
                    exerciseId: "competition_squat", loadKg: 140, reps: 3,
                    rir: 2, velocityMps: nil, setIndex: 1, planItemIndex: 0
                ),
                session: session,
                idempotencyKey: "key-noretry"
            )
            XCTFail("expected a transport failure")
        } catch let error as APIError {
            guard case .transport = error else {
                return XCTFail("expected transport, got \(error)")
            }
        }
        XCTAssertEqual(transport.requests.count, 1)
    }
}

@MainActor
final class Phase2AppModelTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "com.georgesdibpersonalteam.StrengthApp.phase2tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    func testHealthKitImportUsesAJournaledRequestAndRefreshesToday() async {
        let now = Date()
        let hrv = HealthKitReadinessObservation(
            field: .hrvMs,
            value: 55,
            sampleID: "sample-hrv",
            sampleAt: now,
            sourceName: "Apple Watch",
            sourceBundleID: "com.apple.health",
            sourceClass: .appleWatch,
            sourceModel: "Watch6,18",
            sourceManufacturer: "Apple Inc."
        )
        let rhr = HealthKitReadinessObservation(
            field: .rhrBpm,
            value: 52,
            sampleID: "sample-rhr",
            sampleAt: now,
            sourceName: "Apple Watch",
            sourceBundleID: "com.apple.health",
            sourceClass: .appleWatch,
            sourceModel: "Watch6,18",
            sourceManufacturer: "Apple Inc."
        )
        let fake = FakeHealthKitReadinessProvider()
        fake.selection = HealthKitReadinessSelection(hrv: hrv, rhr: rhr, staleFields: [])
        var healthKitBodies: [[String: Any]] = []
        let transport = StubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrapPhase2.utf8))
            case "/api/ios/v1/today":
                return (200, Data(Fixtures.today.utf8))
            case "/api/ios/v1/healthkit/readiness":
                if let data = request.httpBody,
                   let object = try? JSONSerialization.jsonObject(with: data),
                   let body = object as? [String: Any] {
                    healthKitBodies.append(body)
                }
                return (200, Data(Fixtures.readinessWrite.utf8))
            default:
                return (404, Data())
            }
        }
        let (model, defaults, suite, _) = pairedModel(transport: transport, healthKit: fake)
        defer { defaults.removePersistentDomain(forName: suite) }

        await model.onLaunch()
        await model.setHealthKitEnabled(true)

        XCTAssertTrue(model.healthKitEnabled)
        XCTAssertEqual(fake.authorizationRequests, 1)
        XCTAssertEqual(model.healthKitState, .eligibleSample)
        XCTAssertEqual(healthKitBodies.count, 1)
        let samples = healthKitBodies[0]["samples"] as? [[String: Any]] ?? []
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0]["field"] as? String, "hrv_ms")
        XCTAssertEqual(samples[0]["source_class"] as? String, "apple_watch")
        XCTAssertEqual(healthKitBodies[0]["date"] as? String, "2026-11-07")
        XCTAssertTrue(model.pendingMutations.isEmpty)
    }

    func testHealthKitNoSampleIsIndeterminateAndDoesNotPost() async {
        let fake = FakeHealthKitReadinessProvider()
        fake.selection = HealthKitReadinessSelection(
            hrv: nil, rhr: nil, staleFields: []
        )
        var posted = false
        let transport = StubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrapPhase2.utf8))
            case "/api/ios/v1/today":
                return (200, Data(Fixtures.today.utf8))
            case "/api/ios/v1/healthkit/readiness":
                posted = true
                return (200, Data(Fixtures.readinessWrite.utf8))
            default:
                return (404, Data())
            }
        }
        let (model, defaults, suite, _) = pairedModel(transport: transport, healthKit: fake)
        defer { defaults.removePersistentDomain(forName: suite) }

        await model.onLaunch()
        await model.setHealthKitEnabled(true)

        XCTAssertEqual(model.healthKitState, .noEligibleSample)
        XCTAssertFalse(posted)
        XCTAssertTrue(model.pendingMutations.isEmpty)
    }

    private func healthKitSelection() -> HealthKitReadinessSelection {
        let now = Date()
        let hrv = HealthKitReadinessObservation(
            field: .hrvMs, value: 55, sampleID: "sample-hrv", sampleAt: now,
            sourceName: "Apple Watch", sourceBundleID: "com.apple.health",
            sourceClass: .appleWatch, sourceModel: "Watch6,18",
            sourceManufacturer: "Apple Inc."
        )
        let rhr = HealthKitReadinessObservation(
            field: .rhrBpm, value: 52, sampleID: "sample-rhr", sampleAt: now,
            sourceName: "Apple Watch", sourceBundleID: "com.apple.health",
            sourceClass: .appleWatch, sourceModel: "Watch6,18",
            sourceManufacturer: "Apple Inc."
        )
        return HealthKitReadinessSelection(
            hrv: hrv, rhr: rhr, staleFields: []
        )
    }

    private func waitForCounter(_ counter: TestCounter, atLeast target: Int) async {
        for _ in 0..<200 {
            if counter.value >= target { return }
            await Task.yield()
        }
    }

    func testConcurrentRefreshRequestsAreCoalescedWithoutLosingFinalGet() async {
        let gate = TestGate()
        let todayCount = TestCounter()
        let transport = AsyncStubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrapPhase2.utf8))
            case "/api/ios/v1/today":
                let count = todayCount.increment()
                if count == 2 { await gate.wait() }
                return (200, Data(Fixtures.today.utf8))
            default:
                return (404, Data())
            }
        }
        let (model, defaults, suite, _) = pairedModel(transport: transport)
        defer { defaults.removePersistentDomain(forName: suite) }
        await model.onLaunch()

        let first = Task { await model.refresh() }
        await waitForCounter(todayCount, atLeast: 2)
        let second = Task { await model.refresh() }
        await Task.yield()
        await gate.openGate()

        let firstOutcome = await first.value
        let secondOutcome = await second.value
        XCTAssertTrue(firstOutcome.succeeded)
        XCTAssertTrue(secondOutcome.succeeded)
        XCTAssertEqual(todayCount.value, 3)
    }

    func testHealthKitPostSurvivesRefreshFailureWithoutRetryingMutation() async {
        let todayCount = TestCounter()
        let healthKitCount = TestCounter()
        let fake = FakeHealthKitReadinessProvider()
        fake.selection = healthKitSelection()
        let transport = AsyncStubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrapPhase2.utf8))
            case "/api/ios/v1/today":
                let count = todayCount.increment()
                if count >= 2 {
                    return (500, Data(#"{"error":"temporary","code":"server_error"}"#.utf8))
                }
                return (200, Data(Fixtures.today.utf8))
            case "/api/ios/v1/healthkit/readiness":
                _ = healthKitCount.increment()
                return (200, Data(Fixtures.readinessWrite.utf8))
            default:
                return (404, Data())
            }
        }
        let (model, defaults, suite, _) = pairedModel(transport: transport, healthKit: fake)
        defer { defaults.removePersistentDomain(forName: suite) }
        await model.onLaunch()
        await model.setHealthKitEnabled(true)

        XCTAssertEqual(healthKitCount.value, 1)
        XCTAssertNotNil(model.healthKitRefreshError)
        XCTAssertEqual(model.healthKitState, .eligibleSample)
        XCTAssertTrue(model.pendingMutations.isEmpty)
    }

    func testImportStartedDuringRefreshWaitsAndThenRefreshesAgain() async {
        let gate = TestGate()
        let todayCount = TestCounter()
        let healthKitCount = TestCounter()
        let fake = FakeHealthKitReadinessProvider()
        fake.selection = healthKitSelection()
        let transport = AsyncStubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrapPhase2.utf8))
            case "/api/ios/v1/today":
                let count = todayCount.increment()
                if count == 3 { await gate.wait() }
                return (200, Data(Fixtures.today.utf8))
            case "/api/ios/v1/healthkit/readiness":
                _ = healthKitCount.increment()
                return (200, Data(Fixtures.readinessWrite.utf8))
            default:
                return (404, Data())
            }
        }
        let (model, defaults, suite, _) = pairedModel(transport: transport, healthKit: fake)
        defer { defaults.removePersistentDomain(forName: suite) }
        await model.onLaunch()
        await model.setHealthKitEnabled(true)
        XCTAssertEqual(healthKitCount.value, 1)

        let refreshTask = Task { await model.refresh() }
        await waitForCounter(todayCount, atLeast: 3)
        let importTask = Task { await model.importHealthKit() }
        await Task.yield()
        await gate.openGate()
        _ = await refreshTask.value
        await importTask.value

        XCTAssertEqual(healthKitCount.value, 2)
        XCTAssertEqual(todayCount.value, 4)
        XCTAssertNil(model.healthKitRefreshError)
    }

    func testRepVelocityParserAcceptsOptionalDetailAndRejectsBadInput() throws {
        let parsed = try RepVelocityParser.parse("0.62, 0.58 0.54", reps: 3)
        XCTAssertEqual(parsed?.map(\.repIndex), [1, 2, 3])
        XCTAssertEqual(parsed?.map(\.velocityMps), [0.62, 0.58, 0.54])
        XCTAssertNil(try RepVelocityParser.parse("  ", reps: 3))
        XCTAssertThrowsError(try RepVelocityParser.parse("0.62, 0.58, 0.54, 0.50", reps: 3))
        XCTAssertThrowsError(try RepVelocityParser.parse("0.62, nope", reps: 3))
    }

    func testRefreshWithHealthKitDoesNotImportAfterFailedRefresh() async {
        var failToday = false
        let fake = FakeHealthKitReadinessProvider()
        fake.selection = healthKitSelection()
        let transport = AsyncStubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrapPhase2.utf8))
            case "/api/ios/v1/today":
                if failToday {
                    return (500, Data(#"{"error":"temporary","code":"server_error"}"#.utf8))
                }
                return (200, Data(Fixtures.today.utf8))
            case "/api/ios/v1/healthkit/readiness":
                return (200, Data(Fixtures.readinessWrite.utf8))
            default:
                return (404, Data())
            }
        }
        let (model, defaults, suite, _) = pairedModel(
            transport: transport, healthKit: fake, healthKitEnabled: true
        )
        defer { defaults.removePersistentDomain(forName: suite) }
        await model.onLaunch()
        XCTAssertEqual(fake.selectionCalls, 1)

        failToday = true
        await model.refreshWithHealthKit()
        XCTAssertEqual(fake.selectionCalls, 1)
    }

    func testHistoryDetailDecodesOutlineDurationAndSets() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let detail = try decoder.decode(HistoryDetail.self, from: Data(#"""
        {
          "session_id": "s1",
          "occurred_on": "2026-11-08",
          "workout_label": "Squat",
          "session_type": "squat",
          "set_count": 2,
          "duration_min": 44.5,
          "duration_basis": "measured",
          "tonnage_kg": 1200,
          "main_lifts": ["competition_squat"],
          "sets": [
            {"set_id": 1, "exercise_id": "competition_squat", "load_kg": 140, "reps": 3, "rir": 2},
            {"set_id": 2, "exercise_id": "competition_squat", "load_kg": 130, "reps": 5, "rir": 3}
          ]
        }
        """#.utf8))
        XCTAssertEqual(detail.durationMin, 44.5)
        XCTAssertEqual(detail.durationBasis, "measured")
        XCTAssertEqual(detail.sets?.count, 2)
        XCTAssertEqual(detail.sets?.first?.summary, "140.0 kg × 3 · RIR 2")
    }

    func testWorkoutFormRatingLookupDistinguishesCurrentRating() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let workout = try decoder.decode(WorkoutDetail.self, from: Data(#"""
        {
          "workout_id": "w1",
          "status": "in_progress",
          "forms": [
            {"form_id": 1, "exercise_id": "competition_squat", "rating": 4},
            {"form_id": 2, "exercise_id": "competition_bench_press", "rating": 3}
          ]
        }
        """#.utf8))
        XCTAssertEqual(workout.formRating(for: "competition_squat")?.rating, 4)
        XCTAssertEqual(workout.formRating(for: "competition_bench_press")?.rating, 3)
        XCTAssertNil(workout.formRating(for: "competition_deadlift"))
    }

    private func pairedModel(
        transport: HTTPTransport,
        journal: MutationJournal? = nil,
        healthKit: (any HealthKitReadinessProviding)? = nil,
        healthKitEnabled: Bool = false
    ) -> (AppModel, UserDefaults, String, InMemoryTokenStore) {
        let (defaults, suite) = makeDefaults()
        if healthKitEnabled {
            defaults.set(true, forKey: "healthKitReadinessEnabled")
        }
        let store = PairedStore(defaults: defaults)
        store.serverURL = "http://127.0.0.1:8000"
        store.device = PairingDevice(deviceID: "device-1", label: "iPhone")
        let tokens = InMemoryTokenStore(token: "token-abc")
        let model = AppModel(
            client: IOSAPIClient(transport: transport, journal: journal),
            tokens: tokens,
            store: store,
            healthKit: healthKit,
            healthKitDefaults: defaults
        )
        return (model, defaults, suite, tokens)
    }

    func testIssueStartSetAndCompleteFlow() async {
        let transport = StubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrapPhase2.utf8))
            case "/api/ios/v1/today":
                return (200, Data(Fixtures.today.utf8))
            case "/api/ios/v1/prescriptions":
                return (202, Data(Fixtures.planAck.utf8))
            case "/api/ios/v1/plans/current":
                return (200, Data(Fixtures.plansReady.utf8))
            case "/api/ios/v1/workouts":
                return (200, Data(Fixtures.workoutInProgress.utf8))
            case "/api/ios/v1/workouts/workout-1/sets":
                return (200, Data(Fixtures.workoutWithSet.utf8))
            case "/api/ios/v1/workouts/workout-1/complete":
                return (200, Data(Fixtures.workoutCompleted.utf8))
            case "/api/ios/v1/history":
                return (200, Data(Fixtures.history.utf8))
            default:
                return (404, Data())
            }
        }
        let (model, defaults, suite, tokens) = pairedModel(transport: transport)
        defer { defaults.removePersistentDomain(forName: suite) }

        await model.onLaunch()
        XCTAssertEqual(model.phase, .paired)
        XCTAssertTrue(model.canWrite)

        await model.issuePrescription(
            readinessAck: false, idempotencyKey: "issue-1"
        )
        guard case .issued(let issued) = model.prescriptionState else {
            return XCTFail("expected an issued plan")
        }
        XCTAssertEqual(issued.issuedPlanId, "plan-1")

        let started = await model.startWorkout(idempotencyKey: "start-1")
        XCTAssertTrue(started)
        XCTAssertEqual(model.activeWorkout?.workoutId, "workout-1")
        XCTAssertEqual(model.activeWorkout?.status, "in_progress")
        guard case .issued = model.prescriptionState else {
            return XCTFail("the preview must stay presented while the workout is active")
        }

        let added = await model.addSet(
            AddSetRequest(
                exerciseId: "competition_squat", loadKg: 140, reps: 3,
                rir: 2, velocityMps: 0.62, setIndex: 1, planItemIndex: 0
            ),
            idempotencyKey: "set-1"
        )
        XCTAssertTrue(added)
        XCTAssertEqual(model.activeWorkout?.sets?.count, 1)
        XCTAssertEqual(model.activeWorkout?.sets?.first?.velocity, 0.62)

        let completed = await model.completeWorkout(
            CompleteWorkoutRequest(
                sessionRpe: 7, notRecorded: false, durationMin: 45, notes: "test"
            ),
            idempotencyKey: "complete-1"
        )
        XCTAssertTrue(completed)
        XCTAssertNil(model.activeWorkout)
        XCTAssertGreaterThanOrEqual(model.sessions.count, 1)
        XCTAssertNotNil(tokens.token)
    }

    func testConcurrentDuplicateAddSetCallsOnlySendOneMutation() async {
        let transport = AsyncStubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrapPhase2.utf8))
            case "/api/ios/v1/today":
                return (200, Data(Fixtures.today.utf8))
            case "/api/ios/v1/prescriptions":
                return (202, Data(Fixtures.planAck.utf8))
            case "/api/ios/v1/plans/current":
                return (200, Data(Fixtures.plansReady.utf8))
            case "/api/ios/v1/workouts":
                return (200, Data(Fixtures.workoutInProgress.utf8))
            case "/api/ios/v1/workouts/workout-1/sets":
                try await Task.sleep(nanoseconds: 200_000_000)
                return (200, Data(Fixtures.workoutWithSet.utf8))
            default:
                return (404, Data())
            }
        }
        let (model, defaults, suite, _) = pairedModel(transport: transport)
        defer { defaults.removePersistentDomain(forName: suite) }
        await model.onLaunch()
        await model.issuePrescription(
            readinessAck: false, idempotencyKey: "issue-duplicate"
        )
        let started = await model.startWorkout(idempotencyKey: "start-duplicate")
        XCTAssertTrue(started)

        let body = AddSetRequest(
            exerciseId: "competition_squat", loadKg: 140, reps: 3,
            rir: 2, velocityMps: 0.62, setIndex: 1, planItemIndex: 0
        )
        async let first = model.addSet(body, idempotencyKey: "set-duplicate")
        async let second = model.addSet(body, idempotencyKey: "set-duplicate")
        let results = await [first, second]
        XCTAssertEqual(results.filter { $0 }.count, 1)
        let setRequests = transport.requests.filter {
            $0.url?.path == "/api/ios/v1/workouts/workout-1/sets"
        }
        XCTAssertEqual(setRequests.count, 1)
        XCTAssertEqual(setRequests.first?.value(forHTTPHeaderField: "Idempotency-Key"),
                       "set-duplicate")
    }

    func testAmbiguousFailureIsMarkedAndDefinitiveFourHundredIsNot() async {
        let transport = AsyncStubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrapPhase2.utf8))
            case "/api/ios/v1/today":
                return (200, Data(Fixtures.today.utf8))
            case "/api/ios/v1/prescriptions":
                return (202, Data(Fixtures.planAck.utf8))
            case "/api/ios/v1/plans/current":
                return (200, Data(Fixtures.plansReady.utf8))
            case "/api/ios/v1/workouts":
                return (200, Data(Fixtures.workoutInProgress.utf8))
            case "/api/ios/v1/workouts/workout-1/sets":
                return (500, Data())
            default:
                return (404, Data())
            }
        }
        let (model, defaults, suite, _) = pairedModel(transport: transport)
        defer { defaults.removePersistentDomain(forName: suite) }
        await model.onLaunch()
        await model.issuePrescription(
            readinessAck: false, idempotencyKey: "issue-ambiguous"
        )
        let started = await model.startWorkout(idempotencyKey: "start-ambiguous")
        XCTAssertTrue(started)
        let body = AddSetRequest(
            exerciseId: "competition_squat", loadKg: 140, reps: 3,
            rir: 2, velocityMps: nil, setIndex: 1, planItemIndex: 0
        )
        let result = await model.addSet(body, idempotencyKey: "set-ambiguous")
        XCTAssertFalse(result)
        XCTAssertTrue(model.mutationFailureAmbiguous)
    }

    func testLaunchReplaysAPendingAddSetFromTheJournal() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-model-journal-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = MutationJournal(fileURL: url)
        let pending = PendingMutation(
            operationId: "pending-set",
            deviceId: "device-1",
            serverURL: "http://127.0.0.1:8000",
            kind: .addSet,
            targetId: "workout-1",
            path: "api/ios/v1/workouts/workout-1/sets",
            bodyData: Data(#"{"exercise_id":"competition_squat","load_kg":140,"reps":3,"rir":2,"velocity_mps":0.62,"set_index":1,"plan_item_index":0}"#.utf8),
            createdAt: Date(),
            state: .pending
        )
        try journal.record(pending)

        let transport = StubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrapPhase2.utf8))
            case "/api/ios/v1/today":
                return (200, Data(Fixtures.today.utf8))
            case "/api/ios/v1/workouts/workout-1/sets":
                return (200, Data(Fixtures.workoutWithSet.utf8))
            default:
                return (404, Data())
            }
        }
        let (model, defaults, suite, _) = pairedModel(
            transport: transport, journal: journal
        )
        defer { defaults.removePersistentDomain(forName: suite) }

        await model.onLaunch()

        XCTAssertEqual(model.activeWorkout?.workoutId, "workout-1")
        XCTAssertEqual(model.activeWorkout?.sets?.count, 1)
        XCTAssertTrue(model.pendingMutations.isEmpty)
        XCTAssertNil(model.recoveryMessage)
        XCTAssertTrue(
            journal.all(for: "device-1", serverURL: "http://127.0.0.1:8000").isEmpty
        )
    }

    func testReplayConflictIsKeptAndTerminalFourHundredIsRemoved() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("client-conflict-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = MutationJournal(fileURL: url)
        let session = IOSSession(
            baseURL: URL(string: "http://127.0.0.1:8000")!,
            token: "token-abc",
            deviceID: "device-1"
        )
        let conflict = PendingMutation(
            operationId: "conflict-op",
            deviceId: "device-1",
            serverURL: "http://127.0.0.1:8000",
            kind: .addSet,
            targetId: "workout-1",
            path: "api/ios/v1/workouts/workout-1/sets",
            bodyData: Data("{}".utf8),
            createdAt: Date(),
            state: .pending
        )
        let terminal = PendingMutation(
            operationId: "terminal-op",
            deviceId: "device-1",
            serverURL: "http://127.0.0.1:8000",
            kind: .addSet,
            targetId: "workout-1",
            path: "api/ios/v1/workouts/workout-1/sets",
            bodyData: Data("{}".utf8),
            createdAt: Date(),
            state: .pending
        )
        try journal.record(conflict)
        try journal.record(terminal)

        let transport = StubTransport { request in
            let key = request.value(forHTTPHeaderField: "Idempotency-Key")
            if key == "conflict-op" {
                return (409, Data(#"{"error":"operation conflict","code":"idempotency_conflict"}"#.utf8))
            }
            return (409, Data(#"{"error":"workout is not active","code":"workout_not_active"}"#.utf8))
        }
        let client = IOSAPIClient(transport: transport, journal: journal)
        do {
            let _: WorkoutDetail = try await client.replay(conflict, session: session)
            XCTFail("expected a conflict")
        } catch {}
        XCTAssertEqual(
            journal.all(for: "device-1", serverURL: "http://127.0.0.1:8000")
                .first(where: { $0.operationId == "conflict-op" })?.state,
            .conflict
        )

        do {
            let _: WorkoutDetail = try await client.replay(terminal, session: session)
            XCTFail("expected a terminal conflict")
        } catch {}
        XCTAssertNil(
            journal.all(for: "device-1", serverURL: "http://127.0.0.1:8000")
                .first(where: { $0.operationId == "terminal-op" })
        )
    }

    func testLaunchSurfacesServerActiveWorkoutForRecovery() async {
        let activeToday = #"{"date":"2026-11-07","readiness":null,"readiness_score":null,"active_workout":"# + Fixtures.workoutInProgress + "}"
        let transport = StubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrapPhase2.utf8))
            case "/api/ios/v1/today":
                return (200, Data(activeToday.utf8))
            default:
                return (404, Data())
            }
        }
        let (model, defaults, suite, _) = pairedModel(transport: transport)
        defer { defaults.removePersistentDomain(forName: suite) }

        await model.onLaunch()

        guard case .serverActiveWorkout(let workoutId, let sessionType) = model.recoveryIssue else {
            return XCTFail("expected a server active workout recovery state")
        }
        XCTAssertEqual(workoutId, "workout-1")
        XCTAssertEqual(sessionType, "squat")
        XCTAssertEqual(model.activeWorkout?.workoutId, "workout-1")
    }

    func testRefreshSurfacesWorkoutEndedElsewhere() async {
        let transport = StubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrapPhase2.utf8))
            case "/api/ios/v1/today":
                return (200, Data(Fixtures.today.utf8))
            case "/api/ios/v1/prescriptions":
                return (202, Data(Fixtures.planAck.utf8))
            case "/api/ios/v1/plans/current":
                return (200, Data(Fixtures.plansReady.utf8))
            case "/api/ios/v1/workouts":
                return (200, Data(Fixtures.workoutInProgress.utf8))
            default:
                return (404, Data())
            }
        }
        let (model, defaults, suite, _) = pairedModel(transport: transport)
        defer { defaults.removePersistentDomain(forName: suite) }
        await model.onLaunch()
        await model.issuePrescription(
            readinessAck: false, idempotencyKey: "issue-ended"
        )
        let started = await model.startWorkout(idempotencyKey: "start-ended")
        XCTAssertTrue(started)
        XCTAssertEqual(model.activeWorkout?.workoutId, "workout-1")

        await model.refresh()

        guard case .workoutEndedElsewhere(let workoutId) = model.recoveryIssue else {
            return XCTFail("expected a workout-ended recovery state")
        }
        XCTAssertEqual(workoutId, "workout-1")
        XCTAssertNil(model.activeWorkout)
    }

    func testStartSurfacesConsumedPrescriptionRecovery() async {
        // A consumed plan is no longer the device's live row, so the authoritative read must
        // stop reporting it once start fails; a static "ready" would resurrect the preview.
        var consumed = false
        let transport = StubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrapPhase2.utf8))
            case "/api/ios/v1/today":
                return (200, Data(Fixtures.today.utf8))
            case "/api/ios/v1/prescriptions":
                return (202, Data(Fixtures.planAck.utf8))
            case "/api/ios/v1/plans/current":
                return consumed
                    ? (200, Data(#"{"status":"none"}"#.utf8))
                    : (200, Data(Fixtures.plansReady.utf8))
            case "/api/ios/v1/workouts":
                consumed = true
                return (410, Data(#"{"error":"issued plan has already been used","code":"plan_consumed"}"#.utf8))
            default:
                return (404, Data())
            }
        }
        let (model, defaults, suite, _) = pairedModel(transport: transport)
        defer { defaults.removePersistentDomain(forName: suite) }
        await model.onLaunch()
        await model.issuePrescription(
            readinessAck: false, idempotencyKey: "issue-consumed"
        )
        let started = await model.startWorkout(idempotencyKey: "start-consumed")
        XCTAssertFalse(started)
        guard case .prescriptionUnavailable = model.recoveryIssue else {
            return XCTFail("expected a prescription recovery state")
        }
        guard case .idle = model.prescriptionState else {
            return XCTFail("the unusable prescription should be cleared")
        }
    }

    func testReadinessGateBecomesState() async {
        let transport = StubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrapPhase2.utf8))
            case "/api/ios/v1/today":
                return (200, Data(Fixtures.today.utf8))
            case "/api/ios/v1/prescriptions":
                return (409, Data(Fixtures.serverError.utf8))
            default:
                return (404, Data())
            }
        }
        let (model, defaults, suite, _) = pairedModel(transport: transport)
        defer { defaults.removePersistentDomain(forName: suite) }
        await model.onLaunch()
        await model.issuePrescription(
            readinessAck: false, idempotencyKey: "gate-1"
        )
        guard case .readinessRequired(let details) = model.prescriptionState else {
            return XCTFail("expected readinessRequired")
        }
        XCTAssertEqual(details["status"]?.stringValue, "unknown")
        XCTAssertNil(model.mutationError)
    }

    func testProgressLoadsIntoModel() async {
        let transport = StubTransport { request in
            switch request.url?.path {
            case "/api/ios/v1/bootstrap":
                return (200, Data(Fixtures.bootstrapPhase2.utf8))
            case "/api/ios/v1/today":
                return (200, Data(Fixtures.today.utf8))
            case "/api/ios/v1/progress":
                return (200, Data(Fixtures.progress.utf8))
            default:
                return (404, Data())
            }
        }
        let (model, defaults, suite, _) = pairedModel(transport: transport)
        defer { defaults.removePersistentDomain(forName: suite) }
        await model.onLaunch()
        await model.loadProgress(weeks: 8)
        XCTAssertTrue(model.hasLoadedProgress)
        XCTAssertEqual(model.progress?.coverage.sessions, 2)
        XCTAssertEqual(model.progress?.volume.first?.pattern, "squat")
        XCTAssertNil(model.progressError)
    }
}

