import Combine
import Foundation
import StrengthCore

@MainActor
final class TodaySummaryModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case ready(TodaySummary)
        case unavailable(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    let modelLabel: String
    let sendsFactsOffDevice: Bool

    private let generator: any TodaySummaryGenerating
    private let facts: @MainActor () async -> TodaySummaryFacts
    private var generatedFor: String?

    init(
        generator: any TodaySummaryGenerating,
        modelLabel: String,
        sendsFactsOffDevice: Bool,
        facts: @escaping @MainActor () async -> TodaySummaryFacts
    ) {
        self.generator = generator
        self.modelLabel = modelLabel
        self.sendsFactsOffDevice = sendsFactsOffDevice
        self.facts = facts
    }

    var availability: NarrativeAvailability { generator.availability() }

    /// Loads once per state. The state that matters is the day, the readiness answer, the issued
    /// plan and the selected model, which the caller folds into the fingerprint.
    func loadIfNeeded(fingerprint: String) async {
        guard generatedFor != fingerprint else { return }
        await load(fingerprint: fingerprint)
    }

    func refresh(fingerprint: String) async {
        generatedFor = nil
        await load(fingerprint: fingerprint)
    }

    private func load(fingerprint: String) async {
        guard phase != .loading else { return }
        let availability = generator.availability()
        guard availability.isAvailable else {
            phase = .unavailable(availability.reasonText)
            generatedFor = fingerprint
            return
        }
        phase = .loading
        do {
            let summary = try await generator.generate(facts: await facts())
            try TodaySummaryValidator.validate(summary)
            phase = .ready(summary)
        } catch {
            phase = .failed(
                (error as? LocalizedError)?.errorDescription
                    ?? "The summary could not be written."
            )
        }
        // A failure sticks to this state rather than spending a model call on every appearance.
        generatedFor = fingerprint
    }
}
