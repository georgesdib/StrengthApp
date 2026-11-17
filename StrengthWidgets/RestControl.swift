import AppIntents
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

struct OpenWorkoutControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Strength workout"
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}
