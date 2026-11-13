import Foundation

/// Debug-only switch for the simulator smoke test, set by the credential seed launch argument.
/// The watch simulator has no HealthKit workout session, so a smoke run exercises the app flow
/// (fetch → start → log → finish) without it. Release builds never enable this.
enum WatchSmokeMode {
    static var isEnabled: Bool {
#if DEBUG
        UserDefaults.standard.bool(forKey: "watchSmokeEnabled")
#else
        false
#endif
    }
}
