import AppIntents
import StrengthIntents

/// App Shortcuts phrases. Every phrase must contain \(.applicationName) for Siri to match it.
///
/// Keep the total at or below ten phrases: that is the App Shortcuts cap. A phrase that carries a
/// parameter only matches when the parameter can be resolved, so the exercise intents also offer a
/// parameterless phrase that lets Siri ask which exercise to use.
struct StrengthShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TrainingOverviewIntent(),
            phrases: [
                "How is my training going in \(.applicationName)",
            ],
            shortTitle: "Training overview",
            systemImageName: "chart.bar"
        )
        AppShortcut(
            intent: LastWorkoutIntent(),
            phrases: [
                "How long was my last workout in \(.applicationName)",
            ],
            shortTitle: "Last workout",
            systemImageName: "figure.strengthtraining.traditional"
        )
        AppShortcut(
            intent: WeeklyReviewIntent(),
            phrases: [
                "Weekly review in \(.applicationName)",
                "How was last week in \(.applicationName)",
            ],
            shortTitle: "Weekly review",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: AverageSessionDurationIntent(),
            phrases: [
                "Average workout duration in \(.applicationName)",
                "Average session length in \(.applicationName)",
            ],
            shortTitle: "Average duration",
            systemImageName: "timer"
        )
        AppShortcut(
            intent: AverageSessionDuration12WeeksIntent(),
            phrases: [
                "Average workout duration over the last 12 weeks in \(.applicationName)",
            ],
            shortTitle: "Average (12 weeks)",
            systemImageName: "timer"
        )
        AppShortcut(
            intent: ExerciseProgressionIntent(),
            phrases: [
                "How is \(\.$exercise) progressing in \(.applicationName)",
                "How is \(\.$exercise) progression in \(.applicationName)",
                "Exercise progression in \(.applicationName)",
            ],
            shortTitle: "Exercise progression",
            systemImageName: "chart.line.uptrend.xyaxis"
        )
    }
}
