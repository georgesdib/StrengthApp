import AppIntents
import StrengthCore
import SwiftUI
import WidgetKit

/// Control Center, the Lock Screen and the Action button can host this control. It opens the app,
/// which owns starting and ending a rest; the control never writes a training value itself.
struct RestControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.georgesdibpersonalteam.StrengthApp.rest") {
            ControlWidgetButton(action: OpenWorkoutControlIntent()) {
                Label("Strength", systemImage: "figure.strengthtraining.traditional")
            }
        }
        .displayName("Strength workout")
        .description("Open the running workout.")
    }
}

/// Starts the workout card without opening the app, so a watch session's later rests update it
/// without a notification tap. It does nothing unless the phone already has an active workout in
/// its persisted capture; there is no card to start from a blank Today screen.
struct WorkoutCardControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.georgesdibpersonalteam.StrengthApp.workoutcard") {
            ControlWidgetButton(action: StartWorkoutCardIntent()) {
                Label("Workout card", systemImage: "timer")
            }
        }
        .displayName("Workout card")
        .description("Show the active workout on the Lock Screen and in the Dynamic Island.")
    }
}

struct OpenWorkoutControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Strength workout"
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}
