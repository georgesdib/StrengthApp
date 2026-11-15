import Combine
import Foundation
import StrengthCore

@MainActor
final class TrainingChatModel: ObservableObject {
    static let suggested = [
        "What changed this week?",
        "Why is my bench volume down?",
        "How has my squat progressed?",
    ]

    @Published private(set) var messages: [ChatMessage] = []
    @Published var input = ""
    @Published private(set) var isSending = false
    @Published private(set) var errorMessage: String?

    private let generator: any TrainingChatGenerating
    let modelLabel: String

    init(generator: any TrainingChatGenerating, modelLabel: String = "On-device") {
        self.generator = generator
        self.modelLabel = modelLabel
    }

    var availability: NarrativeAvailability { generator.availability() }

    func send(_ text: String? = nil) async {
        let question = (text ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isSending, availability.isAvailable else { return }
        input = ""
        errorMessage = nil
        let history = messages
        messages.append(ChatMessage(role: .user, text: question))
        isSending = true
        defer { isSending = false }
        do {
            let reply = try await generator.reply(to: question, history: history)
            messages.append(
                ChatMessage(
                    role: .assistant,
                    text: reply.text,
                    sources: reply.sources,
                    suggestions: reply.suggestions,
                    unverifiedNumbers: reply.unverifiedNumbers
                )
            )
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "The answer could not be generated."
        }
    }

    func reset() {
        messages = []
        input = ""
        errorMessage = nil
        isSending = false
    }
}


@MainActor
final class UnavailableChatGenerator: TrainingChatGenerating {
    func availability() -> NarrativeAvailability {
        .unavailable("Pair this iPhone with your server to use chat.")
    }

    func reply(to question: String, history: [ChatMessage]) async throws -> ChatReply {
        throw ChatError.unavailable(availability().reasonText)
    }
}
