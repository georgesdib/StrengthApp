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
