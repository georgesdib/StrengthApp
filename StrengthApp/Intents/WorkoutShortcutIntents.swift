import AppIntents
import Foundation
import StrengthCore
import StrengthIntents

/// The phone's intents run in this process; RootView registers the live model here.
@MainActor
enum PhoneIntentBridge {
    static weak var model: AppModel?
}

/// "Start a workout" from the Shortcuts app. It starts the plan the app already requested and takes
/// the owner to the active workout; it never plans or prescribes anything itself.
struct StartWorkoutShortcutIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Workout"
    static var description = IntentDescription(
        "Start the workout your iPhone has already requested, and open it so you can log sets."
    )
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let model = PhoneIntentBridge.model else {
            return IntentAnswer.text("Open StrengthApp first.")
        }
        guard model.phase == .paired else {
            return IntentAnswer.text("Pair this iPhone with your server first.")
        }
        if model.activeWorkout != nil || model.today?.activeWorkout != nil {
            model.requestOpenActiveWorkout()
            return IntentAnswer.text("A workout is already running.")
        }
        guard case .issued = model.prescriptionState else {
            return IntentAnswer.text("No workout is ready. Request one in the app, then try again.")
        }
        let started = await model.startWorkout(idempotencyKey: UUID().uuidString)
        if started {
            model.requestOpenActiveWorkout()
            return IntentAnswer.text("Workout started.")
        }
        return IntentAnswer.text("The workout could not be started. Check the app for the reason.")
    }
}

/// "Finish a workout" from the Shortcuts app. Like the Action button on the watch, it does not
/// finish anything: it opens the running workout, where sRPE is entered and Finish is pressed.
struct FinishWorkoutShortcutIntent: AppIntent {
    static var title: LocalizedStringResource = "Finish Workout"
    static var description = IntentDescription(
        "Open the running workout so you can finish it with sRPE."
    )
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let model = PhoneIntentBridge.model else {
            return IntentAnswer.text("Open StrengthApp first.")
        }
        guard model.activeWorkout != nil || model.today?.activeWorkout != nil else {
            return IntentAnswer.text("No workout is running.")
        }
        model.requestOpenActiveWorkout()
        return IntentAnswer.text("Finish the workout here.")
    }
}
