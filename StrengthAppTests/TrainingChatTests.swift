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
            generator: StubChatGenerator(error: .notGrounded("999"))
        )
        await model.send("What changed?")
        XCTAssertEqual(model.messages.count, 1)
        XCTAssertTrue(model.errorMessage?.contains("999") ?? false)
        model.reset()
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertNil(model.errorMessage)
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
