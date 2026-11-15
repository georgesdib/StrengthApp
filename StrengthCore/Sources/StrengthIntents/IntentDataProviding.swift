import Foundation
import StrengthCore

/// Failures an intent can report to Siri. The text is user-facing: keep it short and actionable.
public enum IntentServiceError: LocalizedError, Equatable {
    /// The app has not been paired with a server yet.
    case notPaired
    /// The app is paired but the request failed. The message comes from the server or transport.
    case requestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notPaired:
            return "Open StrengthApp and pair this iPhone with your server first."
        case .requestFailed(let message):
            return message
        }
    }
}

/// The read-only facts an intent needs. The app implements this over its paired REST session;
/// tests and previews use a stub. Nothing here computes a training value.
///
/// Main-actor bound because the app's API client is: intents hop once with `await`.
@MainActor
public protocol IntentDataProviding: AnyObject {
    func overview() async throws -> IntelligenceEnvelope
    func weeklyReview() async throws -> IntelligenceEnvelope
    func progression(exerciseID: String) async throws -> IntelligenceEnvelope
    func exerciseCatalogue() async throws -> [ExerciseEntity]
    func lastWorkout() async throws -> LastWorkoutSummary?
}

/// Process-wide registration point. The app registers its provider at launch; an intent that runs
/// before registration reports `notPaired` instead of crashing.
@MainActor
public enum IntentServices {
    private static var registered: (any IntentDataProviding)?

    public static func register(_ provider: any IntentDataProviding) {
        registered = provider
    }

    public static func provider() throws -> any IntentDataProviding {
        guard let registered else { throw IntentServiceError.notPaired }
        return registered
    }
}
