import SwiftUI

@main
struct StrengthWatchApp: App {
    @StateObject private var session: WatchSessionController
    @StateObject private var today: WatchTodayController
    @StateObject private var execution: WatchExecutionController

    init() {
        let session = WatchSessionController()
        _session = StateObject(wrappedValue: session)
        _today = StateObject(wrappedValue: WatchTodayController(
            onCredentialsMissing: { session.markCredentialsMissing() }
        ))
        _execution = StateObject(wrappedValue: WatchExecutionController(
            onCredentialsMissing: { session.markCredentialsMissing() }
        ))
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(session: session, today: today, execution: execution)
        }
    }
}
