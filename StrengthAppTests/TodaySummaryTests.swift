import XCTest
@testable import StrengthApp
import StrengthCore

private struct FakeDeepSeek: DeepSeekCompleting {
    var content: String?

    func complete(messages: [DeepSeekMessage], tools: [DeepSeekTool]) async throws -> DeepSeekChatResult {
        DeepSeekChatResult(content: content, toolCalls: [])
    }

    func validateKey() async throws {}
}

private final class CountingGenerator: TodaySummaryGenerating, @unchecked Sendable {
    private let availabilityValue: NarrativeAvailability
    private let summary: TodaySummary?
    private let lock = NSLock()
    private var count = 0

    init(availability: NarrativeAvailability = .available, summary: TodaySummary? = nil) {
        self.availabilityValue = availability
        self.summary = summary
    }

    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func availability() -> NarrativeAvailability { availabilityValue }

    func generate(facts: TodaySummaryFacts) async throws -> TodaySummary {
        lock.lock(); count += 1; lock.unlock()
        guard let summary else { throw NarrativeError.failed("No summary.") }
        return summary
    }
}

@MainActor
final class TodaySummaryModelTests: XCTestCase {
    private let facts = TodaySummaryFacts(
        date: "2026-11-16",
        readinessLogged: true,
        readinessScore: 72,
        sessionLabel: "Lower",
        exerciseCount: 5,
        leadLift: "Back Squat",
        leadLoadKg: 100,
        overviewFacts: "Volume up 6 percent over four weeks."
    )

    func testAnUnavailableGeneratorIsReportedWithoutACall() async {
        let generator = CountingGenerator(availability: .unavailable("Apple Intelligence is off."))
        let model = makeModel(generator)
        await model.loadIfNeeded(fingerprint: "a")
        XCTAssertEqual(model.phase, .unavailable("Apple Intelligence is off."))
        XCTAssertEqual(generator.calls, 0)
    }

    func testOneLoadPerState() async {
        let generator = CountingGenerator(summary: summary())
        let model = makeModel(generator)
        await model.loadIfNeeded(fingerprint: "a")
        await model.loadIfNeeded(fingerprint: "a")
        XCTAssertEqual(generator.calls, 1)
        XCTAssertEqual(model.phase, .ready(summary()))
    }

    func testANewStateAndAManualRefreshBothRegenerate() async {
        let generator = CountingGenerator(summary: summary())
        let model = makeModel(generator)
        await model.loadIfNeeded(fingerprint: "a")
        await model.loadIfNeeded(fingerprint: "b")
        XCTAssertEqual(generator.calls, 2)
        await model.refresh(fingerprint: "b")
        XCTAssertEqual(generator.calls, 3)
    }

    func testAFailureSticksToItsState() async {
        let generator = CountingGenerator(summary: nil)
        let model = makeModel(generator)
        await model.loadIfNeeded(fingerprint: "a")
        XCTAssertEqual(model.phase, .failed("No summary."))
        await model.loadIfNeeded(fingerprint: "a")
        XCTAssertEqual(generator.calls, 1)
    }

    private func summary() -> TodaySummary {
        TodaySummary(
            overview: "Readiness 72 and a lower session is ready.",
            encouragement: "Take the first set seriously and the rest follows.",
            model: .onDevice
        )
    }

    private func makeModel(_ generator: any TodaySummaryGenerating) -> TodaySummaryModel {
        let facts = self.facts
        return TodaySummaryModel(
            generator: generator,
            modelLabel: "On this iPhone",
            sendsFactsOffDevice: false,
            facts: { facts }
        )
    }
}

final class TodaySummaryFactsTests: XCTestCase {
    private let facts = TodaySummaryFacts(
        date: "2026-11-16",
        readinessLogged: true,
        readinessScore: 72,
        sessionLabel: "Lower",
        exerciseCount: 5,
        leadLift: "Back Squat",
        leadLoadKg: 100,
        overviewFacts: "Volume up 6 percent."
    )

    func testFactTextCarriesTheDayTheReadinessAndThePlan() {
        let text = facts.factText
        XCTAssertTrue(text.contains("2026-11-16"))
        XCTAssertTrue(text.contains("72"))
        XCTAssertTrue(text.contains("Lower"))
        XCTAssertTrue(text.contains("100 kg"))
        XCTAssertTrue(text.contains("Volume up 6 percent."))
    }

    func testAnEmptyDayStillProducesFacts() {
        let empty = TodaySummaryFacts(date: "2026-11-16", readinessLogged: false)
        XCTAssertTrue(empty.factText.contains("Readiness is not logged yet."))
        XCTAssertTrue(empty.factText.contains("No session has been issued yet."))
    }

    func testPartialReadinessIsNotReportedAsLoggedOrMissing() {
        let partial = TodaySummaryFacts(
            date: "2026-11-16", readinessLogged: false, readinessPartial: true
        )
        XCTAssertTrue(partial.factText.contains("partly logged"))
        XCTAssertFalse(partial.factText.contains("Readiness is logged."))
        XCTAssertFalse(partial.factText.contains("not logged yet"))
    }

    func testValidatorEnforcesLengthAndContent() throws {
        let fine = TodaySummary(overview: "Fine.", encouragement: "Go.", model: .onDevice)
        XCTAssertNoThrow(try TodaySummaryValidator.validate(fine))

        let long = TodaySummary(
            overview: String(repeating: "a", count: TodaySummary.overviewLimit + 1),
            encouragement: "Go.",
            model: .onDevice
        )
        XCTAssertThrowsError(try TodaySummaryValidator.validate(long))

        let blank = TodaySummary(overview: "  ", encouragement: "Go.", model: .onDevice)
        XCTAssertThrowsError(try TodaySummaryValidator.validate(blank))
    }

    func testDeepSeekParsesTwoLines() async throws {
        let generator = DeepSeekTodaySummaryGenerator(
            api: FakeDeepSeek(content: "OVERVIEW: Three weeks into the block.\nENCOURAGEMENT: One session today and the week is yours."),
            keyPresent: true
        )
        let summary = try await generator.generate(facts: facts)
        XCTAssertEqual(summary.model, .deepSeek)
        XCTAssertEqual(summary.overview, "Three weeks into the block.")
        XCTAssertEqual(summary.encouragement, "One session today and the week is yours.")
    }

    func testDeepSeekWithoutAKeyIsUnavailable() {
        let generator = DeepSeekTodaySummaryGenerator(api: FakeDeepSeek(content: nil), keyPresent: false)
        XCTAssertFalse(generator.availability().isAvailable)
    }

    func testDeepSeekGarbageIsRejected() async {
        let generator = DeepSeekTodaySummaryGenerator(api: FakeDeepSeek(content: "Sure!"), keyPresent: true)
        do {
            _ = try await generator.generate(facts: facts)
            XCTFail("A reply without both passages must not become a card.")
        } catch {
            XCTAssertTrue(error is DeepSeekError)
        }
    }
}

// MARK: - Longevity summary (step 3)

final class LongevitySummaryTests: XCTestCase {
    private func envelope(
        status: String,
        relation: String,
        equivalent: Double,
        vo2Status: String,
        vo2Method: String? = nil,
        remaining: Double = 40
    ) throws -> IntelligenceEnvelope {
        let method = vo2Method.map { "\"method\":\"\($0)\"," } ?? ""
        let json = """
        {"schema_version":"intelligence.envelope.v1","capability":"get_longevity_assessment",
         "status":"\(status)","as_of":"2026-11-18",
         "period":{"start":"2026-11-09","end":"2026-11-15","days":7,"weeks":1,"timezone":"Europe/London"},
         "facts":{
           "last_week":{"value":{"relation":"\(relation)","equivalent_minutes":\(equivalent),
             "remaining_minutes":\(remaining),"reference":{"min_minutes":150,"max_minutes":300}},
             "basis":"derived","method":"m"},
           "current_week":{"value":{"equivalent_minutes":40,"days_remaining":4},
             "basis":"derived","method":"m"},
           "vo2max":{"value":{"status":"\(vo2Status)","value":48,"unit":"ml/kg/min",
             "measured_on":"2026-11-12",\(method)"source":"device"},
             "basis":"observed","method":"m"}
         },
         "coverage":{},"missing":[],"limitations":[]}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(IntelligenceEnvelope.self, from: Data(json.utf8))
    }

    func testWithinReferenceReadsAsContextNotAPass() throws {
        let summary = try XCTUnwrap(LongevitySummary(envelope: envelope(
            status: "ok", relation: "inside", equivalent: 180, vo2Status: "current"
        )))
        XCTAssertTrue(summary.headline.contains("180"))
        XCTAssertTrue(summary.headline.contains("within"))
        XCTAssertFalse(summary.headline.lowercased().contains("target"))
    }

    func testReferenceBoundariesAreWithinTheBand() throws {
        for equivalent in [150.0, 300.0] {
            let summary = try XCTUnwrap(LongevitySummary(envelope: envelope(
                status: "ok", relation: "inside", equivalent: equivalent, vo2Status: "current"
            )))
            XCTAssertTrue(
                summary.headline.contains("within"), "expected within at \(equivalent)"
            )
        }
    }

    func testAboveTheUpperBoundIsItsOwnStateAndNotAVerdict() throws {
        let summary = try XCTUnwrap(LongevitySummary(envelope: envelope(
            status: "ok", relation: "above", equivalent: 340, vo2Status: "current"
        )))
        XCTAssertTrue(summary.headline.contains("340"))
        XCTAssertTrue(summary.headline.contains("above"))
        XCTAssertTrue(summary.headline.contains("not a maximum safe dose"))
        XCTAssertFalse(summary.headline.lowercased().contains("excessive"))
        XCTAssertFalse(summary.headline.lowercased().contains("harmful"))
    }

    func testBelowReferenceStatesTheGap() throws {
        let summary = try XCTUnwrap(LongevitySummary(envelope: envelope(
            status: "ok", relation: "below", equivalent: 110, vo2Status: "absent"
        )))
        XCTAssertTrue(summary.headline.contains("40"))
        XCTAssertTrue(summary.headline.contains("short"))
        XCTAssertTrue(summary.vo2maxLine.contains("No VO₂max measurement recorded"))
        XCTAssertTrue(summary.vo2maxLine.contains("not evidence of poor fitness"))
    }

    func testStaleReadingIsLabelledWithItsProvenance() throws {
        let summary = try XCTUnwrap(LongevitySummary(envelope: envelope(
            status: "ok", relation: "inside", equivalent: 180, vo2Status: "stale",
            vo2Method: "Apple Watch"
        )))
        XCTAssertTrue(summary.vo2maxLine.contains("stale"))
        XCTAssertTrue(summary.vo2maxLine.contains("2026-11-12"))
        XCTAssertTrue(summary.vo2maxLine.contains("48.0"))
        XCTAssertTrue(summary.vo2maxLine.contains("ml/kg/min"))
        XCTAssertTrue(summary.vo2maxLine.contains("Apple Watch"))
    }

    func testIncompleteClassificationDoesNotClaimABelow() throws {
        let summary = try XCTUnwrap(LongevitySummary(envelope: envelope(
            status: "insufficient", relation: "unknown", equivalent: 0, vo2Status: "absent"
        )))
        XCTAssertFalse(summary.headline.lowercased().contains("short"))
        XCTAssertTrue(summary.headline.lowercased().contains("could not be classified"))
    }

    func testFactsCarryTheNumbersForTheModel() throws {
        let summary = try XCTUnwrap(LongevitySummary(envelope: envelope(
            status: "ok", relation: "inside", equivalent: 180, vo2Status: "current"
        )))
        XCTAssertTrue(summary.detail.contains("180"))
        XCTAssertTrue(summary.detail.contains("context only"))
        XCTAssertTrue(summary.detail.contains("4 days left"))
    }

    /// The same JSON fixture the backend test compares against, wrapped in the envelope the
    /// intelligence route returns. If either client changes its interpretation, this fails.
    func testCanonicalAssessmentFixtureIsDecodedIdentically() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/longevity_assessment.ok.json")
        let data = try Data(contentsOf: url)
        guard let assessment = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var lastWeek = assessment["last_week"] as? [String: Any],
              let currentWeek = assessment["current_week"],
              let vo2max = assessment["vo2max"],
              let reference = assessment["reference"] else {
            return XCTFail("the fixture must be the canonical assessment object")
        }
        lastWeek["reference"] = reference
        let envelopeObject: [String: Any] = [
            "schema_version": "intelligence.envelope.v1",
            "capability": "get_longevity_assessment",
            "status": "ok",
            "as_of": assessment["as_of"] ?? "2026-11-18",
            "period": [
                "start": lastWeek["start"] ?? "",
                "end": lastWeek["end"] ?? "",
                "days": 7,
                "weeks": 1,
                "timezone": "Europe/London",
            ],
            "facts": [
                "last_week": ["value": lastWeek, "basis": "derived", "method": "m"],
                "current_week": ["value": currentWeek, "basis": "derived", "method": "m"],
                "vo2max": ["value": vo2max, "basis": "observed", "method": "m"],
            ],
            "coverage": [:],
            "missing": [],
            "limitations": [],
        ]
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let envelope = try decoder.decode(
            IntelligenceEnvelope.self,
            from: try JSONSerialization.data(withJSONObject: envelopeObject)
        )
        let summary = try XCTUnwrap(LongevitySummary(envelope: envelope))
        XCTAssertEqual(summary.relation, "below")
        XCTAssertTrue(summary.headline.contains("140"))
        XCTAssertTrue(summary.headline.contains("10"))
        XCTAssertTrue(summary.detail.contains("30"))
        XCTAssertTrue(summary.vo2maxLine.contains("48.0"))
        XCTAssertTrue(summary.vo2maxLine.contains("ml/kg/min"))
        XCTAssertTrue(summary.vo2maxLine.contains("2026-11-12"))
        XCTAssertTrue(summary.vo2maxLine.contains("Apple Watch"))
        XCTAssertTrue(summary.vo2maxLine.contains("current"))
        XCTAssertEqual(assessment["as_of"] as? String, "2026-11-18")
    }
}

// MARK: - Longevity chat tool gating (step 3)

final class LongevityChatToolTests: XCTestCase {
    func testToolIsOfferedOnlyWithHealthConsent() {
        let withConsent = DeepSeekTools.specs(includeHealth: true).map { $0.function.name }
        let without = DeepSeekTools.specs(includeHealth: false).map { $0.function.name }
        XCTAssertTrue(withConsent.contains("longevity"))
        XCTAssertFalse(without.contains("longevity"))
    }

    func testPlanConsentAndHealthConsentAreIndependent() {
        let planOnly = DeepSeekTools.specs(includePlan: true).map { $0.function.name }
        XCTAssertTrue(planOnly.contains("prescription"))
        XCTAssertFalse(planOnly.contains("longevity"))
    }
}

// MARK: - Activity payload decoding (assessment block)

final class CardioAssessmentDecodeTests: XCTestCase {
    /// The client decodes with .convertFromSnakeCase. This fixture is the real server shape; it
    /// failed silently before because the CodingKeys were written in snake_case.
    func testActivityPayloadDecodesTimeInZone() throws {
        let json = """
        {"summary":{"weeks":[],"rolling":{},"latest_workout_at":null},
         "assessment":{"time_in_zone":{"eligible_workouts":25,"coverage_share":0.421,
           "equivalent_minutes":300.0,"minutes":{"moderate":180.0,"vigorous":60.0},
           "covered_minutes":210.0,"workout_minutes":300.0,"unobserved_minutes":90.0,
           "temporal_coverage_share":0.7,
           "window":{"start":"2026-10-22","end":"2026-11-18","days":28},
           "source":"heart-rate samples"}},
         "recent":[]}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(CardioActivityPayload.self, from: Data(json.utf8))
        let tiz = try XCTUnwrap(payload.assessment?.timeInZone)
        XCTAssertEqual(tiz.eligibleWorkouts, 25)
        XCTAssertEqual(tiz.windowDays, 28)
        XCTAssertEqual(tiz.moderateMinutes, 180, accuracy: 0.001)
        XCTAssertEqual(tiz.vigorousMinutes, 60, accuracy: 0.001)
        XCTAssertEqual(tiz.coverageShare, 0.421, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(tiz.coveredMinutes), 210, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(tiz.workoutMinutes), 300, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(tiz.unobservedMinutes), 90, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(tiz.temporalCoverageShare), 0.7, accuracy: 0.001)
    }

    func testPayloadWithoutTheAssessmentStillDecodes() throws {
        let json = """
        {"summary":{"weeks":[],"rolling":{},"latest_workout_at":null},"recent":[]}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(CardioActivityPayload.self, from: Data(json.utf8))
        XCTAssertNil(payload.assessment)
    }
}
