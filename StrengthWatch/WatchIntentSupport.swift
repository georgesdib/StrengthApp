import AppIntents
import Foundation
import StrengthCore
import StrengthIntents

/// Intents run in this process and can arrive before the SwiftUI scene exists, so the app
/// registers its live controllers here when it starts.
@MainActor
enum WatchIntentBridge {
    static weak var today: WatchTodayController?
    static weak var execution: WatchExecutionController?
}

/// Read-only facts for watch intents, over the watch's own device credential.
@MainActor
final class WatchIntentDataProvider: IntentDataProviding {
    private let store: WatchCredentialStore
    private let client = IOSAPIClient()

    init(store: WatchCredentialStore = WatchCredentialStore()) {
        self.store = store
    }

    private func session() throws -> IOSSession {
        guard let stored = store.stored,
              let token = store.loadToken(),
              let url = URL(string: stored.homeBaseURL) else {
            throw IntentServiceError.notPaired
        }
        return IOSSession(baseURL: url, token: token, deviceID: stored.deviceID)
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
