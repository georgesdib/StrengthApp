import Foundation
import StrengthCore
import StrengthIntents

/// Live read-only facts for App Intents. It reuses the paired session stored by the app and the
/// same REST client, so an intent never computes a training value or talks to anything else.
final class LiveIntentDataProvider: IntentDataProviding {
    private let client: IOSAPIClient
    private let tokens: TokenStoring
    private let store: PairedStore

    init(
        client: IOSAPIClient? = nil,
        tokens: TokenStoring? = nil,
        store: PairedStore? = nil
    ) {
        self.client = client ?? IOSAPIClient(journal: MutationJournal())
        self.tokens = tokens ?? KeychainTokenStore()
        self.store = store ?? PairedStore()
    }

    private func session() throws -> IOSSession {
        let urlString = store.serverURL ?? store.homeServerURL
        guard let urlString, let baseURL = try? IOSAPIClient.validatedBaseURL(urlString),
              let token = tokens.load(), let device = store.device else {
            throw IntentServiceError.notPaired
        }
        return IOSSession(baseURL: baseURL, token: token, deviceID: device.deviceID)
    }

    func overview(windowWeeks: Int) async throws -> IntelligenceEnvelope {
        try await client.overview(session: session(), windowWeeks: windowWeeks)
    }

    func weeklyReview() async throws -> IntelligenceEnvelope {
        try await client.weeklyReview(session: session())
    }

    func progression(exerciseID: String) async throws -> IntelligenceEnvelope {
        try await client.progression(session: session(), exerciseID: exerciseID)
    }

    func exerciseCatalogue() async throws -> [ExerciseEntity] {
        let response = try await client.exerciseCatalogue(session: session())
        return response.exercises.map { ExerciseEntity(id: $0.id, name: $0.display) }
    }

    func lastWorkout() async throws -> LastWorkoutSummary? {
        let history = try await client.history(session: session(), limit: 1)
        guard let newest = history.sessions.first else { return nil }
        return LastWorkoutSummary(
            occurredOn: newest.occurredOn,
            sessionType: newest.sessionType,
            durationMin: newest.durationMin,
            workingSets: newest.workingSetCount,
            mainLifts: newest.mainLifts
        )
    }
}
