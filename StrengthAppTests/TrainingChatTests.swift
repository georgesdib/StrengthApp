import XCTest
import StrengthCore
@testable import StrengthApp

@MainActor
private final class StubChatGenerator: TrainingChatGenerating {
    let availabilityValue: NarrativeAvailability
    let replyValue: ChatReply?
    let errorValue: ChatError?

    init(availability: NarrativeAvailability = .available,
         reply: ChatReply? = ChatReply(text: "Two sessions this week.", sources: ["weekly review"]),
         error: ChatError? = nil) {
        self.availabilityValue = availability
        self.replyValue = reply
        self.errorValue = error
    }

    func availability() -> NarrativeAvailability { availabilityValue }

    func reply(to question: String, history: [ChatMessage]) async throws -> ChatReply {
        if let errorValue { throw errorValue }
        return replyValue!
    }
}

@MainActor
final class TrainingChatTests: XCTestCase {
    func testSendAppendsQuestionAndGroundedReply() async {
        let model = TrainingChatModel(generator: StubChatGenerator())
        await model.send("What changed this week?")
        XCTAssertEqual(model.messages.count, 2)
        XCTAssertEqual(model.messages.first?.role, .user)
        XCTAssertEqual(model.messages.last?.role, .assistant)
        XCTAssertEqual(model.messages.last?.sources, ["weekly review"])
        XCTAssertNil(model.errorMessage)
    }

    func testUnavailableModelDoesNotSend() async {
        let model = TrainingChatModel(
            generator: StubChatGenerator(availability: .unavailable("No model"), reply: nil)
        )
        await model.send("hello")
        XCTAssertTrue(model.messages.isEmpty)
    }

    func testFailureIsShownAndSessionCanBeReset() async {
        let model = TrainingChatModel(
            generator: StubChatGenerator(error: .failed("No answer"))
        )
        await model.send("What changed?")
        XCTAssertEqual(model.messages.count, 1)
        XCTAssertTrue(model.errorMessage?.contains("No answer") ?? false)
        model.reset()
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testUnverifiedNumbersAreCarriedToTheMessage() async {
        let model = TrainingChatModel(
            generator: StubChatGenerator(
                reply: ChatReply(
                    text: "Five sessions and 9 sets.", sources: ["weekly review"],
                    unverifiedNumbers: ["9"]
                )
            )
        )
        await model.send("What changed?")
        XCTAssertEqual(model.messages.last?.unverifiedNumbers, ["9"])
    }

    func testSuggestionsAreCarriedToTheMessage() async {
        let model = TrainingChatModel(
            generator: StubChatGenerator(
                reply: ChatReply(
                    text: "Two sessions.", sources: ["weekly review"],
                    suggestions: ["Try 105 kg."]
                )
            )
        )
        await model.send("What should I change?")
        XCTAssertEqual(model.messages.last?.suggestions, ["Try 105 kg."])
    }

    func testPromptCarriesTodayAndKeepsTheQuestion() {
        let prompt = ChatPrompt.build(question: "what was prescribed yesterday", history: [])
        XCTAssertTrue(prompt.contains("Today:"))
        XCTAssertTrue(prompt.contains("what was prescribed yesterday"))
    }

    func testRawToolOutputsAreCarriedToTheMessage() async {
        let model = TrainingChatModel(
            generator: StubChatGenerator(
                reply: ChatReply(
                    text: "Two sessions.", sources: ["weekly review"],
                    rawOutputs: [ChatToolOutput(source: "weekly review", text: "activity: 2")]
                )
            )
        )
        await model.send("What changed?")
        XCTAssertEqual(model.messages.last?.rawOutputs.first?.source, "weekly review")
        XCTAssertEqual(model.messages.last?.rawOutputs.first?.text, "activity: 2")
    }

    func testPlanCardIsCarriedToTheMessage() async {
        let card = PrescriptionCard(
            forDate: "2026-11-14", sessionType: "bench_hinge",
            items: [
                .init(
                    id: "0-bench", exerciseID: "bench_press_narrow", sets: 4,
                    repsLow: 3, repsHigh: 5, loadKg: 92, loadBasis: "external",
                    rir: 3, restS: 180
                ),
            ]
        )
        let model = TrainingChatModel(
            generator: StubChatGenerator(
                reply: ChatReply(text: "Prescription.", sources: ["prescription"], planCard: card)
            )
        )
        await model.send("What was prescribed?")
        XCTAssertEqual(model.messages.last?.planCard?.forDate, "2026-11-14")
        XCTAssertEqual(model.messages.last?.planCard?.items.count, 1)
    }

    func testPromptKeepsOnlyTheRecentTurns() {
        let history = (0..<10).map {
            ChatMessage(role: .user, text: "question \($0) \(String(repeating: "x", count: 500))")
        }
        let prompt = ChatPrompt.build(question: "current", history: history, maxCharacters: 1_200)
        XCTAssertLessThanOrEqual(prompt.count, 1_200)
        XCTAssertTrue(prompt.contains("current"))
        XCTAssertFalse(prompt.contains("question 0 "))
    }

    func testQuestionTimeWindowGroundsAnEchoedWindow() throws {
        let questionTime = ChatPrompt.timeNumbers(in: "how has it progressed over the last 3 months?")
        XCTAssertTrue(questionTime.contains("3"))
        let allowed = ChatPrompt.allowedNumbers(
            data: ["2"], questionTime: questionTime,
            answer: "Over the last 3 months it moved 2 kg."
        )
        XCTAssertTrue(allowed.contains("3"))
        XCTAssertNoThrow(
            try NarrativeValidator.validate(
                text: "Over the last 3 months it moved 2 kg.", allowedNumbers: allowed
            )
        )
    }

    func testQuestionTimeWindowCannotGroundAnUnrelatedValue() {
        let allowed = ChatPrompt.allowedNumbers(
            data: ["2"], questionTime: ["3"], answer: "You did 3 sessions."
        )
        XCTAssertFalse(allowed.contains("3"))
        XCTAssertThrowsError(
            try NarrativeValidator.validate(text: "You did 3 sessions.", allowedNumbers: allowed)
        )
    }

    func testChatGuardRejectsAnUngroundedNumber() throws {
        XCTAssertThrowsError(
            try NarrativeValidator.validate(
                text: "You did 999 sessions.", allowedNumbers: ["2", "3"]
            )
        ) { error in
            guard case NarrativeError.notGrounded("999") = error else {
                return XCTFail("expected notGrounded, got \(error)")
            }
        }
        XCTAssertNoThrow(
            try NarrativeValidator.validate(
                text: "You did 2 sessions.", allowedNumbers: ["2", "3"]
            )
        )
    }

    func testChatGuardRejectsOverlongAnswers() {
        XCTAssertThrowsError(
            try NarrativeValidator.validate(
                text: String(repeating: "a", count: 3_000), allowedNumbers: [], maxLength: 2_500
            )
        ) { error in
            guard case NarrativeError.tooLong = error else {
                return XCTFail("expected tooLong, got \(error)")
            }
        }
    }
}
