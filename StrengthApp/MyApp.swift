import SwiftUI
import StrengthCore
import StrengthIntents

@main
struct MyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Siri and Shortcuts run intents in this process; register the read-only provider once.
        IntentServices.register(LiveIntentDataProvider())
        // Which build is installed is otherwise unanswerable from the phone; the install script
        // stamps it into Info.plist and this records it where it can be read back.
        BuildStamp.record()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
