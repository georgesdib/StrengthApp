import SwiftUI
import StrengthCore
import StrengthIntents

@main
struct MyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Siri and Shortcuts run intents in this process; register the read-only provider once.
        IntentServices.register(LiveIntentDataProvider())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
