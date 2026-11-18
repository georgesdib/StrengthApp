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
        vo2Status: String
    ) throws -> IntelligenceEnvelope {
        let json = """
        {"schema_version":"intelligence.envelope.v1","capability":"get_longevity_assessment",
         "status":"\(status)","as_of":"2026-11-18",
         "period":{"start":"2026-11-09","end":"2026-11-15","days":7,"weeks":1,"timezone":"Europe/London"},
         "facts":{
           "last_week":{"value":{"relation":"\(relation)","equivalent_minutes":\(equivalent),
             "remaining_minutes":40,"reference":{"min_minutes":150,"max_minutes":300}},
             "basis":"derived","method":"m"},
           "current_week":{"value":{"equivalent_minutes":40,"days_remaining":4},
             "basis":"derived","method":"m"},
           "vo2max":{"value":{"status":"\(vo2Status)","value":48,"measured_on":"2026-11-12"},
             "basis":"observed","method":"m"}
         },
         "coverage":{},"missing":[],"limitations":[]}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(IntelligenceEnvelope.self, from: Data(json.utf8))
    }

    func testInsideReferenceReadsAsContextNotAPass() throws {
        let summary = try XCTUnwrap(LongevitySummary(envelope: envelope(
            status: "ok", relation: "inside", equivalent: 180, vo2Status: "current"
        )))
        XCTAssertTrue(summary.headline.contains("180"))
        XCTAssertTrue(summary.headline.contains("inside"))
        XCTAssertFalse(summary.headline.lowercased().contains("target"))
    }

    func testBelowReferenceStatesTheGap() throws {
        let summary = try XCTUnwrap(LongevitySummary(envelope: envelope(
            status: "ok", relation: "below", equivalent: 110, vo2Status: "absent"
        )))
        XCTAssertTrue(summary.headline.contains("40"))
        XCTAssertTrue(summary.headline.contains("short"))
        XCTAssertEqual(summary.vo2maxLine, "No VO₂max measurement recorded.")
    }

    func testStaleReadingIsLabelled() throws {
        let summary = try XCTUnwrap(LongevitySummary(envelope: envelope(
            status: "ok", relation: "inside", equivalent: 180, vo2Status: "stale"
        )))
        XCTAssertTrue(summary.vo2maxLine.contains("stale"))
        XCTAssertTrue(summary.vo2maxLine.contains("2026-11-12"))
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
