import AppIntents
import Foundation
import StrengthCore
import os

/// One provider lookup and one error mapping for the phone and the watch. Intents stay read-only:
/// this helper only carries the server's result or turns a transport error into the same message.
@MainActor
public enum IntentCall {
    private static let logger = Logger(
        subsystem: "com.georgesdibpersonalteam.StrengthApp",
        category: "intents"
    )

    public static func run<T>(
        _ label: String = #function,
        _ body: () async throws -> T
    ) async throws -> T {
        do {
            let value = try await body()
            logger.debug("intent \(label, privacy: .public) ok")
            return value
        } catch let error as IntentServiceError {
            logger.error(
                "intent \(label, privacy: .public) failed: \(String(describing: error), privacy: .public)"
            )
            throw error
        } catch {
            logger.error(
                "intent \(label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            throw IntentServiceError.requestFailed(error.localizedDescription)
        }
    }
}

/// A dialog-only answer that is also the intent's String output, so an action exposes the same
/// sentence it speaks. The watch has no snippet card; the phone's start/finish actions have none.
public enum IntentAnswer {
    public static func text(
        _ text: String
    ) -> IntentResultContainer<String, Never, Never, IntentDialog> {
        .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

/// Fetches the read-only facts behind an intent answer. Both app targets call this so the provider
/// lookup, error mapping and envelope fetch cannot drift apart. The digest and the view stay with
/// the target that presents them.
@MainActor
public enum ReadOnlyIntentQuery {
    public static func overview(windowWeeks: Int) async throws -> IntelligenceEnvelope {
        try await IntentCall.run {
            let provider = try IntentServices.provider()
            return try await provider.overview(windowWeeks: windowWeeks)
        }
    }

    public static func weeklyReview() async throws -> IntelligenceEnvelope {
        try await IntentCall.run {
            let provider = try IntentServices.provider()
            return try await provider.weeklyReview()
        }
    }

    public static func progression(exerciseID: String) async throws -> IntelligenceEnvelope {
        try await IntentCall.run {
            let provider = try IntentServices.provider()
            return try await provider.progression(exerciseID: exerciseID)
        }
    }

    public static func lastWorkout() async throws -> LastWorkoutSummary? {
        try await IntentCall.run {
            let provider = try IntentServices.provider()
            return try await provider.lastWorkout()
        }
    }
}
