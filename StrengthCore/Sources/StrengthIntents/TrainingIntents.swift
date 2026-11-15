import AppIntents
import Foundation
import StrengthCore

/// Shared entry point for the four read-only intents: one provider lookup, one error mapping.
enum IntentCall {
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

/// "How is my training going?" — the deterministic overview envelope, spoken.
public struct TrainingOverviewIntent: AppIntent {
    public static var title: LocalizedStringResource = "Training Overview"
    public static var description = IntentDescription(
        "Summarise recent training from your own server: sessions, adherence and readiness coverage."
    )
    public static var openAppWhenRun: Bool = false

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let envelope = try await IntentCall.run {
            let provider = try await IntentServices.provider()
            return try await provider.overview()
        }
        return .result(dialog: IntentDialog(stringLiteral: OverviewDigest(envelope: envelope).dialog))
    }
}

/// "How long was my previous workout?" — the newest history row, spoken.
public struct LastWorkoutIntent: AppIntent {
    public static var title: LocalizedStringResource = "Last Workout"
    public static var description = IntentDescription(
        "Say when your most recent workout was, how long it lasted and how many working sets it had."
    )
    public static var openAppWhenRun: Bool = false

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let summary = try await IntentCall.run {
            let provider = try await IntentServices.provider()
            return try await provider.lastWorkout()
        }
        guard let summary else {
            return .result(dialog: "You have no completed workouts yet.")
        }
        return .result(dialog: IntentDialog(stringLiteral: summary.dialog))
    }
}

/// "How is my trap bar deadlift progressing?" — one exercise's deterministic progression envelope.
public struct ExerciseProgressionIntent: AppIntent {
    public static var title: LocalizedStringResource = "Exercise Progression"
    public static var description = IntentDescription(
        "Describe one exercise's strength trend from your own server, with the session count behind it."
    )
    public static var openAppWhenRun: Bool = false

    @Parameter(title: "Exercise")
    public var exercise: ExerciseEntity?

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("How is \(\.$exercise) progressing?")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let entity = exercise else {
            return .result(dialog: "Name an exercise, for example your main lift.")
        }
        let envelope = try await IntentCall.run {
            let provider = try await IntentServices.provider()
            return try await provider.progression(exerciseID: entity.id)
        }
        let digest = ProgressionDigest(envelope: envelope)
        return .result(dialog: IntentDialog(stringLiteral: digest.dialog(fallbackName: entity.name)))
    }
}

/// "How was last week?" — the deterministic weekly review, spoken.
public struct WeeklyReviewIntent: AppIntent {
    public static var title: LocalizedStringResource = "Weekly Review"
    public static var description = IntentDescription(
        "Summarise the last completed training week: sessions, working sets and the strongest movement."
    )
    public static var openAppWhenRun: Bool = false

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let envelope = try await IntentCall.run {
            let provider = try await IntentServices.provider()
            return try await provider.weeklyReview()
        }
        return .result(dialog: IntentDialog(stringLiteral: WeeklyReviewDigest(envelope: envelope).dialog))
    }
}
