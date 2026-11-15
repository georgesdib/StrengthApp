import AppIntents
import StrengthIntents

/// App Shortcuts phrases. Every phrase must contain \(.applicationName) for Siri to match it.
struct StrengthShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TrainingOverviewIntent(),
            phrases: [
                "How is my training going in \(.applicationName)",
                "Training overview in \(.applicationName)",
            ],
            shortTitle: "Training overview",
            systemImageName: "chart.bar"
        )
        AppShortcut(
            intent: LastWorkoutIntent(),
            phrases: [
                "How long was my last workout in \(.applicationName)",
                "When was my last workout in \(.applicationName)",
            ],
            shortTitle: "Last workout",
            systemImageName: "figure.strengthtraining.traditional"
        )
        AppShortcut(
            intent: WeeklyReviewIntent(),
            phrases: [
                "How was last week in \(.applicationName)",
                "Weekly review in \(.applicationName)",
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
            intent: ExerciseProgressionIntent(),
            phrases: [
                "How is \(\.$exercise) progressing in \(.applicationName)",
            ],
            shortTitle: "Exercise progression",
            systemImageName: "chart.line.uptrend.xyaxis"
        )
    }
}
