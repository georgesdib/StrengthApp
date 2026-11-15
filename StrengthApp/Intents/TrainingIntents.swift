import AppIntents
import Foundation
import StrengthCore
import StrengthIntents
import SwiftUI
import os

/// Shared entry point for the read-only intents: one provider lookup, one error mapping.
@MainActor
enum IntentCall {
    private static let logger = Logger(
        subsystem: "com.georgesdibpersonalteam.StrengthApp",
        category: "intents"
    )

    static func run<T>(_ label: String = #function, _ body: () async throws -> T) async throws -> T {
        do {
            let value = try await body()
            logger.debug("intent \(label, privacy: .public) ok")
            return value
        } catch let error as IntentServiceError {
            logger.error("intent \(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw error
        } catch {
            logger.error("intent \(label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw IntentServiceError.requestFailed(error.localizedDescription)
        }
    }
}

/// "How is my training going?" — the deterministic overview envelope, spoken and drawn.
struct TrainingOverviewIntent: AppIntent {
    static var title: LocalizedStringResource = "Training Overview"
    static var description = IntentDescription(
        "Summarise recent training from your own server: sessions, adherence and readiness coverage."
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ShowsSnippetView & ProvidesDialog {
        let envelope = try await IntentCall.run {
            let provider = try await IntentServices.provider()
            return try await provider.overview(windowWeeks: 4)
        }
        let digest = OverviewDigest(envelope: envelope)
        return .result(
            dialog: IntentDialog(stringLiteral: digest.dialog),
            view: OverviewSnippetView(digest: digest)
        )
    }
}

/// "How long was my previous workout?" — the newest history row, spoken and drawn.
struct LastWorkoutIntent: AppIntent {
    static var title: LocalizedStringResource = "Last Workout"
    static var description = IntentDescription(
        "Say when your most recent workout was, how long it lasted and how many working sets it had."
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ShowsSnippetView & ProvidesDialog {
        let summary = try await IntentCall.run {
            let provider = try await IntentServices.provider()
            return try await provider.lastWorkout()
        }
        guard let summary else {
            return .result(
                dialog: "You have no completed workouts yet.",
                view: LastWorkoutSnippetView(summary: nil)
            )
        }
        return .result(
            dialog: IntentDialog(stringLiteral: summary.dialog),
            view: LastWorkoutSnippetView(summary: summary)
        )
    }
}

/// "What was my average workout duration over the past N weeks?" — the envelope's window aggregate.
struct AverageSessionDurationIntent: AppIntent {
    static var title: LocalizedStringResource = "Average Workout Duration"
    static var description = IntentDescription(
        "Report the average session duration over a number of weeks, with the sample size behind it."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Weeks", default: 4, inclusiveRange: (lowerBound: 1, upperBound: 52))
    var weeks: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Average workout duration over the last \(\.$weeks) weeks")
    }

    func perform() async throws -> some IntentResult & ShowsSnippetView & ProvidesDialog {
        let window = weeks
        let envelope = try await IntentCall.run {
            let provider = try await IntentServices.provider()
            return try await provider.overview(windowWeeks: window)
        }
        let digest = AverageDurationDigest(envelope: envelope, weeks: window)
        return .result(
            dialog: IntentDialog(stringLiteral: digest.dialog),
            view: AverageDurationSnippetView(digest: digest)
        )
    }
}

/// "How is my trap bar deadlift progressing?" — one exercise's deterministic progression envelope.
struct ExerciseProgressionIntent: AppIntent {
    static var title: LocalizedStringResource = "Exercise Progression"
    static var description = IntentDescription(
        "Describe one exercise's strength trend from your own server, with the session count behind it."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Exercise")
    var exercise: ExerciseEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("How is \(\.$exercise) progressing?")
    }

    func perform() async throws -> some IntentResult & ShowsSnippetView & ProvidesDialog {
        guard let entity = exercise else {
            return .result(
                dialog: "Name an exercise, for example your main lift.",
                view: ProgressionSnippetView(name: "Exercise", direction: nil, changeKg: nil, sessions: nil)
            )
        }
        let envelope = try await IntentCall.run {
            let provider = try await IntentServices.provider()
            return try await provider.progression(exerciseID: entity.id)
        }
        let digest = ProgressionDigest(envelope: envelope)
        return .result(
            dialog: IntentDialog(stringLiteral: digest.dialog(fallbackName: entity.name)),
            view: ProgressionSnippetView(
                name: digest.exerciseDisplay ?? entity.name,
                direction: digest.direction,
                changeKg: digest.changeKg,
                sessions: digest.sessions
            )
        )
    }
}

/// "How was last week?" — the deterministic weekly review, spoken and drawn.
struct WeeklyReviewIntent: AppIntent {
    static var title: LocalizedStringResource = "Weekly Review"
    static var description = IntentDescription(
        "Summarise the last completed training week: sessions, working sets and the strongest movement."
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ShowsSnippetView & ProvidesDialog {
        let envelope = try await IntentCall.run {
            let provider = try await IntentServices.provider()
            return try await provider.weeklyReview()
        }
        let digest = WeeklyReviewDigest(envelope: envelope)
        return .result(
            dialog: IntentDialog(stringLiteral: digest.dialog),
            view: WeeklyReviewSnippetView(digest: digest)
        )
    }
}
