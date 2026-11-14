import StrengthCore
import SwiftUI

@main
struct StrengthWatchApp: App {
    @StateObject private var session: WatchSessionController
    @StateObject private var today: WatchTodayController
    @StateObject private var execution: WatchExecutionController

    init() {
#if DEBUG
        Self.seedSmokeCredentialIfRequested()
#endif
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

#if DEBUG
    /// UI-test seam: the simulator smoke test seeds a credential instead of pairing a phone
    /// simulator. Launch arguments arrive as UserDefaults through XCUIApplication, and only a
    /// Debug build honours them.
    private static func seedSmokeCredentialIfRequested() {
        let defaults = UserDefaults.standard
        guard let url = defaults.string(forKey: "watchSmokeServerURL"),
              let token = defaults.string(forKey: "watchSmokeToken"),
              let device = defaults.string(forKey: "watchSmokeDeviceID"),
              !url.isEmpty, !token.isEmpty, !device.isEmpty else { return }
        defaults.set(true, forKey: "watchSmokeEnabled")
        // A session saved by an earlier run would launch straight into the execution view.
        try? FileManager.default.removeItem(at: WatchExecutionController.recordFileURL)
        let store = WatchCredentialStore()
        store.clear()
        let context = WatchCredentialContext(
            epoch: Int(Date().timeIntervalSince1970),
            configVersion: Int(Date().timeIntervalSince1970),
            homeBaseURL: url,
            deviceID: device,
            token: token,
            issuedAt: ServerClock.encodedISO(Date())
        )
        _ = try? store.apply(context)
    }
#endif
}
