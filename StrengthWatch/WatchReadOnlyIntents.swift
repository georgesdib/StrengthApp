import AppIntents
import Foundation
import StrengthCore
import StrengthIntents

struct WatchLastWorkoutIntent: AppIntent {
    static var title: LocalizedStringResource = "Last Workout"
    static var description = IntentDescription("Say when your latest workout was and how long it lasted.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let summary = try await ReadOnlyIntentQuery.lastWorkout()
        guard let summary else {
            return IntentAnswer.text("You have no completed workouts yet.")
        }
        return IntentAnswer.text(summary.dialog)
    }
}

struct WatchOverviewIntent: AppIntent {
    static var title: LocalizedStringResource = "Training Overview"
    static var description = IntentDescription("Summarise recent training: sessions, adherence and readiness coverage.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let envelope = try await ReadOnlyIntentQuery.overview(windowWeeks: 4)
        return IntentAnswer.text(OverviewDigest(envelope: envelope).dialog)
    }
}

struct WatchWeeklyReviewIntent: AppIntent {
    static var title: LocalizedStringResource = "Weekly Review"
    static var description = IntentDescription("Summarise the last completed training week.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let envelope = try await ReadOnlyIntentQuery.weeklyReview()
        return IntentAnswer.text(WeeklyReviewDigest(envelope: envelope).dialog)
    }
}

struct WatchProgressionIntent: AppIntent {
    static var title: LocalizedStringResource = "Exercise Progression"
    static var description = IntentDescription("Describe one exercise's strength trend.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Exercise")
    var exercise: ExerciseEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let entity = exercise else {
            return IntentAnswer.text("Name an exercise, for example your main lift.")
        }
        let envelope = try await ReadOnlyIntentQuery.progression(exerciseID: entity.id)
        let digest = ProgressionDigest(envelope: envelope)
        return IntentAnswer.text(digest.dialog(fallbackName: entity.name))
    }
}

/// Watch phrases are declared here because App Shortcuts are per app target: the phone's do not
/// reach the watch. One phrase each keeps well inside the limit.
struct WatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WatchLastWorkoutIntent(),
            phrases: ["How long was my last workout in \(.applicationName)"],
            shortTitle: "Last workout",
            systemImageName: "figure.strengthtraining.traditional"
        )
        AppShortcut(
            intent: WatchOverviewIntent(),
            phrases: ["How is my training going in \(.applicationName)"],
            shortTitle: "Training overview",
            systemImageName: "chart.bar"
        )
        AppShortcut(
            intent: WatchWeeklyReviewIntent(),
            phrases: ["Weekly review in \(.applicationName)"],
            shortTitle: "Weekly review",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: WatchProgressionIntent(),
            phrases: ["Exercise progression in \(.applicationName)"],
            shortTitle: "Exercise progression",
            systemImageName: "chart.line.uptrend.xyaxis"
        )
    }
}
