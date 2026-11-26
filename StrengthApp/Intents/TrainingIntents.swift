import AppIntents
import Foundation
import StrengthCore
import StrengthIntents
import SwiftUI

/// "How is my training going?" — the deterministic overview envelope, spoken and drawn.
struct TrainingOverviewIntent: AppIntent {
    static var title: LocalizedStringResource = "Training Overview"
    static var description = IntentDescription(
        "Summarise recent training from your own server: sessions, adherence and readiness coverage."
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String>
        & ShowsSnippetView & ProvidesDialog {
        let envelope = try await ReadOnlyIntentQuery.overview(windowWeeks: 4)
        let digest = OverviewDigest(envelope: envelope)
        let text = digest.dialog
        return .result(
            value: text,
            dialog: IntentDialog(stringLiteral: text),
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

    func perform() async throws -> some IntentResult & ReturnsValue<String>
        & ShowsSnippetView & ProvidesDialog {
        let summary = try await ReadOnlyIntentQuery.lastWorkout()
        guard let summary else {
            let text = "You have no completed workouts yet."
            return .result(
                value: text,
                dialog: IntentDialog(stringLiteral: text),
                view: LastWorkoutSnippetView(summary: nil)
            )
        }
        let text = summary.dialog
        return .result(
            value: text,
            dialog: IntentDialog(stringLiteral: text),
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

    func perform() async throws -> some IntentResult & ReturnsValue<String>
        & ShowsSnippetView & ProvidesDialog {
        let window = weeks
        let envelope = try await ReadOnlyIntentQuery.overview(windowWeeks: window)
        let digest = AverageDurationDigest(envelope: envelope, weeks: window)
        let text = digest.dialog
        return .result(
            value: text,
            dialog: IntentDialog(stringLiteral: text),
            view: AverageDurationSnippetView(digest: digest)
        )
    }
}

/// "Average workout duration over the last 12 weeks" — the same aggregate over a fixed window.
///
/// A separate intent exists because an App Shortcut phrase cannot carry a free-form number: a
/// parameter in a phrase needs a fixed option set. This gives the exact sentence a literal match
/// instead of falling through to Siri's model, which just opened the app.
struct AverageSessionDuration12WeeksIntent: AppIntent {
    static var title: LocalizedStringResource = "Average Workout Duration (12 weeks)"
    static var description = IntentDescription(
        "Report the average session duration over the last 12 weeks, with the sample size behind it."
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String>
        & ShowsSnippetView & ProvidesDialog {
        let envelope = try await ReadOnlyIntentQuery.overview(windowWeeks: 12)
        let digest = AverageDurationDigest(envelope: envelope, weeks: 12)
        let text = digest.dialog
        return .result(
            value: text,
            dialog: IntentDialog(stringLiteral: text),
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

    func perform() async throws -> some IntentResult & ReturnsValue<String>
        & ShowsSnippetView & ProvidesDialog {
        guard let entity = exercise else {
            let text = "Name an exercise, for example your main lift."
            return .result(
                value: text,
                dialog: IntentDialog(stringLiteral: text),
                view: ProgressionSnippetView(name: "Exercise", direction: nil, changeKg: nil, sessions: nil)
            )
        }
        let envelope = try await ReadOnlyIntentQuery.progression(exerciseID: entity.id)
        let digest = ProgressionDigest(envelope: envelope)
        let text = digest.dialog(fallbackName: entity.name)
        return .result(
            value: text,
            dialog: IntentDialog(stringLiteral: text),
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

    func perform() async throws -> some IntentResult & ReturnsValue<String>
        & ShowsSnippetView & ProvidesDialog {
        let envelope = try await ReadOnlyIntentQuery.weeklyReview()
        let digest = WeeklyReviewDigest(envelope: envelope)
        let text = digest.dialog
        return .result(
            value: text,
            dialog: IntentDialog(stringLiteral: text),
            view: WeeklyReviewSnippetView(digest: digest)
        )
    }
}
