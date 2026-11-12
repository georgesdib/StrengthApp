import SwiftUI

@main
struct StrengthWatchApp: App {
    @StateObject private var session: WatchSessionController
    @StateObject private var today: WatchTodayController
    @StateObject private var execution: WatchExecutionController

    init() {
        let session = WatchSessionController()
        let execution = WatchExecutionController(
            onCredentialsMissing: { session.markCredentialsMissing() }
        )
        _session = StateObject(wrappedValue: session)
        _today = StateObject(wrappedValue: WatchTodayController(
            onCredentialsMissing: { session.markCredentialsMissing() }
        ))
        _execution = StateObject(wrappedValue: execution)
        // §7.8: a home-server change waits until the session is finished and the outbox empty.
        session.onExecutionPayload = { [weak execution] in
            execution?.applyRemotePayload($0)
        }
        session.canApplyConfig = { [weak execution] in
            guard let execution else { return false }
            return execution.phase == .ready && execution.pendingCount == 0
        }
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(session: session, today: today, execution: execution)
        }
    }
}
