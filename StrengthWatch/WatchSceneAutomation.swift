import Foundation
import StrengthCore

/// Runs the HomeKit scenes the phone chose, when a session is started, finished or discarded here.
///
/// The mapping arrives in the watch credential context; the phone is the only place it is chosen.
/// Execution is best-effort and once per session and event.
@MainActor
enum WatchSceneAutomation {
    static let startKey = "ios.watch.automation.startScene"
    static let endKey = "ios.watch.automation.endScene"
    private static let firedKey = "ios.watch.automation.fired"
    private static let firedLimit = 20

    static func store(start: String?, end: String?) {
        let defaults = UserDefaults.standard
        defaults.set(start, forKey: startKey)
        defaults.set(end, forKey: endKey)
    }

    static func run(event: String, sessionID: String) async {
        let defaults = UserDefaults.standard
        let key = event == "started" ? startKey : endKey
        guard let json = defaults.string(forKey: key),
              let scene = SceneSelection.decode(json) else { return }

        let fired = sessionID + ":" + event
        var keys = defaults.stringArray(forKey: firedKey) ?? []
        guard !keys.contains(fired) else { return }
        keys.append(fired)
        if keys.count > firedLimit {
            keys.removeFirst(keys.count - firedLimit)
        }
        defaults.set(keys, forKey: firedKey)

        if !(await HomeKitSceneRunner.shared.run(scene)) {
            // A refused or missing scene is retried on a later transition only.
            defaults.set(keys.filter { $0 != fired }, forKey: firedKey)
        }
    }
}
