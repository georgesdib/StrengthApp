import AppIntents
import Foundation
import StrengthCore
import StrengthIntents

/// One provider lookup and one error mapping, mirroring the phone's intents.
@MainActor
enum WatchIntentCall {
    static func run<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as IntentServiceError {
            throw error
        } catch {
            throw IntentServiceError.requestFailed(error.localizedDescription)
        }
    }
}

struct WatchLastWorkoutIntent: AppIntent {
    static var title: LocalizedStringResource = "Last Workout"
    static var description = IntentDescription("Say when your latest workout was and how long it lasted.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let summary = try await WatchIntentCall.run {
            let provider = try await IntentServices.provider()
            return try await provider.lastWorkout()
        }
        guard let summary else {
            return .result(dialog: "You have no completed workouts yet.")
        }
        return .result(dialog: IntentDialog(stringLiteral: summary.dialog))
    }
}

struct WatchOverviewIntent: AppIntent {
    static var title: LocalizedStringResource = "Training Overview"
    static var description = IntentDescription("Summarise recent training: sessions, adherence and readiness coverage.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let envelope = try await WatchIntentCall.run {
            let provider = try await IntentServices.provider()
            return try await provider.overview(windowWeeks: 4)
        }
        return .result(dialog: IntentDialog(stringLiteral: OverviewDigest(envelope: envelope).dialog))
    }
}

struct WatchWeeklyReviewIntent: AppIntent {
    static var title: LocalizedStringResource = "Weekly Review"
    static var description = IntentDescription("Summarise the last completed training week.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let envelope = try await WatchIntentCall.run {
            let provider = try await IntentServices.provider()
            return try await provider.weeklyReview()
        }
        return .result(dialog: IntentDialog(stringLiteral: WeeklyReviewDigest(envelope: envelope).dialog))
    }
}

struct WatchProgressionIntent: AppIntent {
    static var title: LocalizedStringResource = "Exercise Progression"
    static var description = IntentDescription("Describe one exercise's strength trend.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Exercise")
    var exercise: ExerciseEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let entity = exercise else {
            return .result(dialog: "Name an exercise, for example your main lift.")
        }
        let envelope = try await WatchIntentCall.run {
            let provider = try await IntentServices.provider()
            return try await provider.progression(exerciseID: entity.id)
        }
        let digest = ProgressionDigest(envelope: envelope)
        return .result(dialog: IntentDialog(stringLiteral: digest.dialog(fallbackName: entity.name)))
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
