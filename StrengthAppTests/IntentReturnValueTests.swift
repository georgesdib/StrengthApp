import AppIntents
import XCTest

@testable import StrengthApp
import StrengthIntents

@MainActor
final class IntentReturnValueTests: XCTestCase {
    /// Every Shortcuts action exposes its answer as a String output, not only as a dialog.
    /// This is a compile-time guard: dropping `ReturnsValue<String>` from one of these intents
    /// breaks the corresponding line.
    func testPhoneIntentsReturnTheirAnswerAsText() {
        requireStringOutput(TrainingOverviewIntent())
        requireStringOutput(LastWorkoutIntent())
        requireStringOutput(AverageSessionDurationIntent())
        requireStringOutput(AverageSessionDuration12WeeksIntent())
        requireStringOutput(ExerciseProgressionIntent())
        requireStringOutput(WeeklyReviewIntent())
        requireStringOutput(StartWorkoutShortcutIntent())
        requireStringOutput(FinishWorkoutShortcutIntent())
    }

    func testSharedAnswerUsesTheTextAsItsOutput() {
        let answer = IntentAnswer.text("Workout started.")

        XCTAssertEqual(answer.value, "Workout started.")
    }

    private func requireStringOutput<I: AppIntent>(_: I) where I.PerformResult: ReturnsValue<String> {}
}
