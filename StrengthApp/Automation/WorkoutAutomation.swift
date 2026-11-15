import Foundation
import os
import StrengthCore
import UIKit

/// The two lifecycle moments an automation can run on.
enum WorkoutEvent: String {
    case started
    case ended
}

/// Opens a URL in another app. Injected so the automation is testable without a device.
protocol ShortcutURLOpening {
    func open(_ url: URL) async -> Bool
}

struct SystemShortcutURLOpener: ShortcutURLOpening {
    func open(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { opened in
                continuation.resume(returning: opened)
            }
        }
    }
}

/// Runs the owner's automations when a workout starts or ends.
///
/// Decisions recorded in the plan (INT-7b-1/7b-2, 2026-11-15):
/// - both events are supported;
/// - there is no separate toggle: a filled-in shortcut name or a chosen scene means the channel is on;
/// - nothing is passed to the Shortcut — no session data, no duration, no text;
/// - ordering is scene first, then the Shortcut, because the Shortcut foregrounds Shortcuts;
/// - each channel fires at most once per session and event, even across relaunches.
///
/// Automation is best-effort. It never blocks, delays or rolls back a workout.
final class WorkoutAutomation {
    static let shared = WorkoutAutomation()

    static let startShortcutKey = "ios.automation.startShortcut"
    static let endShortcutKey = "ios.automation.endShortcut"
    static let startSceneKey = "ios.automation.startScene"
    static let endSceneKey = "ios.automation.endScene"
    private static let firedKey = "ios.automation.fired"
    private static let firedLimit = 20

    private let defaults: UserDefaults
    private let opener: ShortcutURLOpening
    private let sceneRunner: SceneRunning
    private let logger = Logger(
        subsystem: "com.georgesdibpersonalteam.StrengthApp",
        category: "automation"
    )

    init(
        defaults: UserDefaults = .standard,
        opener: ShortcutURLOpening = SystemShortcutURLOpener(),
        sceneRunner: SceneRunning? = nil
    ) {
        self.defaults = defaults
        self.opener = opener
        self.sceneRunner = sceneRunner ?? HomeKitSceneRunner.shared
    }

    // MARK: - Configuration

    var startShortcut: String {
        get { (defaults.string(forKey: Self.startShortcutKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        set { defaults.set(newValue, forKey: Self.startShortcutKey) }
    }

    var endShortcut: String {
        get { (defaults.string(forKey: Self.endShortcutKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        set { defaults.set(newValue, forKey: Self.endShortcutKey) }
    }

    var startScene: SceneSelection? {
        get { SceneSelection.decode(defaults.string(forKey: Self.startSceneKey)) }
        set { defaults.set(newValue?.jsonString, forKey: Self.startSceneKey) }
    }

    var endScene: SceneSelection? {
        get { SceneSelection.decode(defaults.string(forKey: Self.endSceneKey)) }
        set { defaults.set(newValue?.jsonString, forKey: Self.endSceneKey) }
    }

    func shortcut(for event: WorkoutEvent) -> String {
        event == .started ? startShortcut : endShortcut
    }

    func scene(for event: WorkoutEvent) -> SceneSelection? {
        event == .started ? startScene : endScene
    }

    // MARK: - Running

    /// Runs the configured channels for one session transition: scene first, then the Shortcut.
    /// Returns whether any channel ran.
    @discardableResult
    func handle(_ event: WorkoutEvent, sessionID: String) async -> Bool {
        let eventKey = "\(sessionID):\(event.rawValue)"
        var ran = false

        if let selection = scene(for: event) {
            let key = "\(eventKey):scene"
            if !hasFired(key) {
                markFired(key)
                if await sceneRunner.run(selection) {
                    ran = true
                } else {
                    // A refused or missing scene is retried on a later transition only.
                    clearFired(key)
                }
            }
        }

        let name = shortcut(for: event)
        if !name.isEmpty {
            let key = "\(eventKey):shortcut"
            if !hasFired(key), let url = Self.url(forShortcutNamed: name) {
                markFired(key)
                if await opener.open(url) {
                    ran = true
                } else {
                    clearFired(key)
                    logger.error("the system refused the shortcut URL")
                }
            }
        }
        return ran
    }

    /// Runs a named Shortcut once, for the Settings test button. No dedupe, no session.
    @discardableResult
    func test(_ name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = Self.url(forShortcutNamed: trimmed) else { return false }
        return await opener.open(url)
    }

    /// The scenes currently available from HomeKit, for the Settings pickers.
    func availableScenes() async -> [SceneSelection] {
        await sceneRunner.scenes()
    }

    /// Runs one scene once, for the Settings test button. No dedupe, no session.
    @discardableResult
    func testScene(_ selection: SceneSelection) async -> Bool {
        await sceneRunner.run(selection)
    }

    static func url(forShortcutNamed name: String) -> URL? {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        return components.url
    }

    // MARK: - Fired log

    private func hasFired(_ key: String) -> Bool {
        firedKeys().contains(key)
    }

    private func markFired(_ key: String) {
        var keys = firedKeys()
        keys.removeAll { $0 == key }
        keys.append(key)
        if keys.count > Self.firedLimit {
            keys.removeFirst(keys.count - Self.firedLimit)
        }
        defaults.set(keys, forKey: Self.firedKey)
    }

    private func clearFired(_ key: String) {
        defaults.set(firedKeys().filter { $0 != key }, forKey: Self.firedKey)
    }

    private func firedKeys() -> [String] {
        defaults.stringArray(forKey: Self.firedKey) ?? []
    }
}
