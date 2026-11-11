import StrengthCore
import SwiftUI

/// Chooses between Today (no session) and the running session, and funnels scene-phase events
/// into the controllers so the retry bursts and HealthKit liveness follow the app's life.
struct WatchRootView: View {
    @ObservedObject var session: WatchSessionController
    @ObservedObject var today: WatchTodayController
    @ObservedObject var execution: WatchExecutionController
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if execution.phase == .ready {
                WatchTodayView(today: today, execution: execution)
            } else {
                WatchExecutionView(execution: execution)
            }
        }
        .task {
            session.start()
            execution.load()
            await today.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                session.sceneBecameActive()
                Task { await execution.sceneBecameActive() }
                if case .ready = session.state, execution.phase == .ready {
                    Task { await today.refresh() }
                }
            } else {
                execution.sceneWillResign()
            }
        }
        .onChange(of: execution.phase) { _, phase in
            if phase == .ready || phase == .abandoned {
                Task { await today.refresh() }
            }
        }
        .onChange(of: session.state) { _, state in
            switch state {
            case .ready:
                Task { await today.refresh() }
            case .revoked:
                today.credentialsUnavailable()
            default:
                break
            }
        }
    }
}
