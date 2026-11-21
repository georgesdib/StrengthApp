import Foundation
import os
import StrengthCore
import SwiftUI

/// Runs the HomeKit scenes the phone chose, when a session is started, finished or discarded here.
///
/// The mapping arrives in the watch credential context and on its own user-info channel; the phone
/// is the only place it is chosen. Execution is best-effort and once per session and event.
///
/// Everything it decides is published in `status`, so the wrist can show why a scene did not run
/// instead of failing silently.
@MainActor
final class WatchSceneAutomation: ObservableObject {
    static let shared = WatchSceneAutomation()

    /// What the watch can say about itself without a Mac and a console.
    struct Status: Equatable {
        var startLabel: String?
        var endLabel: String?
        var lastEvent: String?
        var lastResult: String?
        var lastRunAt: Date?
        var homes: Int?
        var isRunning = false

        var hasMapping: Bool { startLabel != nil || endLabel != nil }

        /// One line for the watch screen: the mapping, then what happened last.
        var summary: String {
            guard hasMapping else { return "No scenes from iPhone" }
            var parts: [String] = []
            if let startLabel { parts.append("Start: \(startLabel)") }
            if let endLabel { parts.append("End: \(endLabel)") }
            if let lastResult { parts.append(lastResult) }
            return parts.joined(separator: " · ")
        }
    }

    static let startKey = "ios.watch.automation.startScene"
    static let endKey = "ios.watch.automation.endScene"
    private static let firedKey = "ios.watch.automation.fired"
    private static let firedLimit = 20

    @Published private(set) var status = Status()

    private let defaults: UserDefaults
    private let runner: SceneRunning
    private let logger = Logger(
        subsystem: "com.georgesdibpersonalteam.StrengthApp",
        category: "watch.automation"
    )

    init(defaults: UserDefaults = .standard, runner: SceneRunning = HomeKitSceneRunner.shared) {
        self.defaults = defaults
        self.runner = runner
        refresh()
    }

    func store(start: String?, end: String?) {
        defaults.set(start, forKey: Self.startKey)
        defaults.set(end, forKey: Self.endKey)
        logger.log("scene mapping stored: start=\(start != nil, privacy: .public) end=\(end != nil, privacy: .public)")
        refresh()
    }

    /// Reads the scene labels out of storage; call after the mapping or the home list may have
    /// changed.
    func refresh() {
        status.startLabel = SceneSelection.decode(defaults.string(forKey: Self.startKey))?.label
        status.endLabel = SceneSelection.decode(defaults.string(forKey: Self.endKey))?.label
        status.homes = runner.homeCount
    }

    /// Asks HomeKit for the home list at app launch, so the system's Home access prompt appears
    /// while the owner is looking at the app rather than in the middle of a set.
    func preload() async {
        guard status.hasMapping || Self.mappingExists(in: defaults) else { return }
        if let live = runner as? HomeKitSceneRunner {
            await live.preload()
        }
        refresh()
    }

    func run(event: String, sessionID: String) async {
        let key = event == "started" ? Self.startKey : Self.endKey
        guard let json = defaults.string(forKey: key),
              let scene = SceneSelection.decode(json) else {
            logger.log("scene \(event, privacy: .public): no scene chosen on the iPhone")
            status.lastEvent = event
            status.lastResult = "No scene for \(event)"
            status.lastRunAt = Date()
            return
        }

        let fired = sessionID + ":" + event
        var keys = defaults.stringArray(forKey: Self.firedKey) ?? []
        guard !keys.contains(fired) else { return }
        keys.append(fired)
        if keys.count > Self.firedLimit {
            keys.removeFirst(keys.count - Self.firedLimit)
        }
        defaults.set(keys, forKey: Self.firedKey)

        status.isRunning = true
        let ran = await runner.run(scene)
        status.isRunning = false
        status.lastEvent = event
        status.lastRunAt = Date()
        refresh()
        if ran {
            status.lastResult = "\(event == "started" ? "Start" : "End") scene ran"
            logger.log("scene \(event, privacy: .public) ran")
        } else {
            // A refused or missing scene is retried on a later transition only.
            defaults.set(keys.filter { $0 != fired }, forKey: Self.firedKey)
            status.lastResult = failureText()
            logger.error("scene \(event, privacy: .public) failed: \(self.status.lastResult ?? "-", privacy: .public)")
        }
    }

    /// Runs the start scene now, without a session, so the owner can tell a HomeKit problem from a
    /// workout-path problem.
    func testStartScene() async {
        guard let json = defaults.string(forKey: Self.startKey),
              let scene = SceneSelection.decode(json) else {
            status.lastResult = "No start scene chosen on the iPhone"
            status.lastRunAt = Date()
            return
        }
        status.isRunning = true
        let ran = await runner.run(scene)
        status.isRunning = false
        refresh()
        status.lastRunAt = Date()
        status.lastResult = ran ? "Test ran" : failureText()
    }

    private func failureText() -> String {
        if let homes = status.homes, homes == 0 {
            return "No Home access on Apple Watch"
        }
        return "Scene did not run"
    }

    private static func mappingExists(in defaults: UserDefaults) -> Bool {
        defaults.string(forKey: startKey) != nil || defaults.string(forKey: endKey) != nil
    }
}
