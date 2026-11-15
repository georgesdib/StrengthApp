import Foundation
import os
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

/// Runs a user-named Shortcut when a workout starts or ends.
///
/// Decisions recorded in the plan (INT-7b-1, 2026-11-15):
/// - both events are supported;
/// - there is no separate toggle: a filled-in name means the channel is on, an empty one means off;
/// - nothing is passed to the Shortcut — no session data, no duration, no text.
///
/// The automation is best-effort. It never blocks, delays or rolls back a workout, and it fires at
/// most once per session and event, even across relaunches.
final class WorkoutAutomation {
    static let shared = WorkoutAutomation()

    static let startShortcutKey = "ios.automation.startShortcut"
    static let endShortcutKey = "ios.automation.endShortcut"
    private static let firedKey = "ios.automation.fired"
    private static let firedLimit = 20

    private let defaults: UserDefaults
    private let opener: ShortcutURLOpening
    private let logger = Logger(
        subsystem: "com.georgesdibpersonalteam.StrengthApp",
        category: "automation"
    )

    init(defaults: UserDefaults = .standard, opener: ShortcutURLOpening = SystemShortcutURLOpener()) {
        self.defaults = defaults
        self.opener = opener
    }

    var startShortcut: String {
        get { (defaults.string(forKey: Self.startShortcutKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        set { defaults.set(newValue, forKey: Self.startShortcutKey) }
    }

    var endShortcut: String {
        get { (defaults.string(forKey: Self.endShortcutKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        set { defaults.set(newValue, forKey: Self.endShortcutKey) }
    }

    func shortcut(for event: WorkoutEvent) -> String {
        event == .started ? startShortcut : endShortcut
    }

    /// Fires the configured Shortcut for one session transition. Returns whether a URL was opened.
    @discardableResult
    func handle(_ event: WorkoutEvent, sessionID: String) async -> Bool {
        let name = shortcut(for: event)
        guard !name.isEmpty else { return false }
        let key = "\(sessionID):\(event.rawValue)"
        guard !hasFired(key) else { return false }
        guard let url = Self.url(forShortcutNamed: name) else {
            logger.error("cannot build a run-shortcut URL")
            return false
        }
        // Mark before opening: a re-entrant transition must not fire twice.
        markFired(key)
        let opened = await opener.open(url)
        if !opened {
            // The system refused the URL (Shortcuts missing or the name is malformed). Clear the
            // mark so a later transition can try again, and keep the workout unaffected.
            clearFired(key)
            logger.error("the system refused the shortcut URL")
        }
        return opened
    }

    /// Runs a named Shortcut once, for the Settings test button. No dedupe, no session.
    @discardableResult
    func test(_ name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = Self.url(forShortcutNamed: trimmed) else { return false }
        return await opener.open(url)
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
