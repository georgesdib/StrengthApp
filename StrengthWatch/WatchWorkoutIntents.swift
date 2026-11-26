import AppIntents
import Foundation
import StrengthCore
import StrengthIntents

/// The Action button needs one style; the issued plan decides what the session actually contains.
enum StrengthWorkoutStyle: String, AppEnum {
    case strength

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Workout")
    static var caseDisplayRepresentations: [StrengthWorkoutStyle: DisplayRepresentation] = [
        .strength: DisplayRepresentation(title: "Strength"),
    ]
}

/// Registers Strength under Settings > Action button > Workout. Apple requires this intent to be
/// compiled into the watch app, never an AppIntentsExtension.
struct ActionButtonStartWorkoutIntent: StartWorkoutIntent {
    static var title: LocalizedStringResource = "Start Workout"
    static var description = IntentDescription("Start the workout your iPhone has already requested for this watch.")
    static var openAppWhenRun: Bool = true

    static var suggestedWorkouts: [ActionButtonStartWorkoutIntent] = [ActionButtonStartWorkoutIntent()]

    @Parameter(title: "Workout")
    var workoutStyle: StrengthWorkoutStyle

    init() {
        workoutStyle = .strength
    }

    var displayRepresentation: DisplayRepresentation {
        StrengthWorkoutStyle.caseDisplayRepresentations[workoutStyle]
            ?? DisplayRepresentation(title: "Strength")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let today = WatchIntentBridge.today, let execution = WatchIntentBridge.execution else {
            return IntentAnswer.text("Open Strength on your watch first.")
        }
        guard execution.phase == .ready else {
            return IntentAnswer.text("A workout is already running.")
        }
        await today.refresh()
        guard case .ready(let plan) = today.state else {
            return IntentAnswer.text("No workout is ready. Request one on your iPhone, then try again.")
        }
        await execution.start(issuedPlanID: plan.issuedPlanID)
        return IntentAnswer.text("Starting your workout.")
    }
}

/// Donated as the Action button's next action while a session is running. The owner chose the
/// "open the finish screen" behaviour, so this does not finish anything by itself: it brings the
/// session forward so sRPE can be entered.
struct ActionButtonOpenFinishIntent: AppIntent {
    static var title: LocalizedStringResource = "Finish Workout"
    static var description = IntentDescription("Opens the running workout so you can finish it with sRPE.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let execution = WatchIntentBridge.execution else {
            return IntentAnswer.text("Open Strength on your watch first.")
        }
        guard execution.phase != .ready else {
            return IntentAnswer.text("No workout is running. Request one on your iPhone first.")
        }
        execution.requestOpenFinish()
        return IntentAnswer.text("Finish the workout here.")
    }
}
