import SwiftUI

@main
struct StrengthWatchApp: App {
    @StateObject private var session: WatchSessionController
    @StateObject private var today: WatchTodayController
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let session = WatchSessionController()
        _session = StateObject(wrappedValue: session)
        _today = StateObject(wrappedValue: WatchTodayController(
            onCredentialsMissing: { session.markCredentialsMissing() }
        ))
    }

    var body: some Scene {
        WindowGroup {
            WatchTodayView(today: today)
                .task {
                    session.start()
                    await today.refresh()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    session.sceneBecameActive()
                    if case .ready = session.state {
                        Task { await today.refresh() }
                    }
                }
                .onChange(of: session.state) { _, state in
                    if case .ready = state {
                        Task { await today.refresh() }
                    } else if case .revoked = state {
                        today.credentialsUnavailable()
                    }
                }
        }
    }
}
