import Foundation
import HomeKit
import os

/// One HomeKit scene the owner picked for a workout event.
///
/// Only identifiers and a display label are stored: no accessory data, no home structure.
public struct SceneSelection: Codable, Equatable, Sendable {
    public let homeID: String
    public let sceneID: String
    public let label: String

    public init(homeID: String, sceneID: String, label: String) {
        self.homeID = homeID
        self.sceneID = sceneID
        self.label = label
    }

    public var jsonString: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ json: String?) -> SceneSelection? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SceneSelection.self, from: data)
    }
}

/// The scene mapping as its own WatchConnectivity message, so a changed choice reaches the watch
/// even when the credential context itself is unchanged (that slot is shared with the handshake).
public enum WatchSceneMapping {
    public static let kind = "scenes"

    /// An empty string means "the phone has no scene for this event", which is different from a
    /// field that is absent because no mapping was ever sent.
    public static func message(start: String?, end: String?) -> [String: Any] {
        [
            "kind": kind,
            "start": start ?? "",
            "end": end ?? "",
        ]
    }

    /// nil when the message is not a scene mapping.
    public static func decode(_ message: [String: Any]) -> (start: String?, end: String?)? {
        guard (message["kind"] as? String) == kind,
              let start = message["start"] as? String,
              let end = message["end"] as? String else { return nil }
        return (start.isEmpty ? nil : start, end.isEmpty ? nil : end)
    }
}

/// Runs HomeKit scenes. Behind a protocol so the automation is testable without a home.
@MainActor
public protocol SceneRunning: AnyObject {
    func scenes() async -> [SceneSelection]
    func run(_ selection: SceneSelection) async -> Bool
    /// The number of homes HomeKit returned the last time it loaded, or nil when unknown. This is
    /// the only signal HomeKit gives for "access refused" versus "no home configured".
    var homeCount: Int? { get }
}

public extension SceneRunning {
    var homeCount: Int? { nil }
}

/// Live HomeKit executor. Best-effort: a denied authorisation, a deleted home or a missing scene
/// returns `false` and never throws into the workout path.
@MainActor
public final class HomeKitSceneRunner: NSObject, SceneRunning, HMHomeManagerDelegate {
    public static let shared = HomeKitSceneRunner()

    private let manager: HMHomeManager
    private let homes = HomesWaiters()
    private let logger = Logger(
        subsystem: "com.georgesdibpersonalteam.StrengthApp",
        category: "automation"
    )

    public override init() {
        manager = HMHomeManager()
        super.init()
        // HMHomeManager loads asynchronously. The delegate is weak, so the shared runner must
        // own the manager and stay alive for the first update (including an empty home list).
        manager.delegate = self
    }

    public func scenes() async -> [SceneSelection] {
        await waitForHomes()
        return manager.homes.flatMap { home in
            home.actionSets.map { set in
                SceneSelection(
                    homeID: home.uniqueIdentifier.uuidString,
                    sceneID: set.uniqueIdentifier.uuidString,
                    label: home.name + " — " + set.name
                )
            }
        }
    }

    public func run(_ selection: SceneSelection) async -> Bool {
        await waitForHomes()
        guard let home = manager.homes.first(where: {
            $0.uniqueIdentifier.uuidString == selection.homeID
        }) else {
            logger.error(
                "scene home not found; skipping (homes: \(self.manager.homes.count, privacy: .public))"
            )
            return false
        }
        guard let set = home.actionSets.first(where: {
            $0.uniqueIdentifier.uuidString == selection.sceneID
        }) else {
            logger.error("scene not found; skipping")
            return false
        }
        let executed = await withCheckedContinuation { continuation in
            home.executeActionSet(set) { error in
                if let error {
                    self.logger.error("scene failed: \(error.localizedDescription, privacy: .public)")
                }
                continuation.resume(returning: error == nil)
            }
        }
        return executed
    }

    /// Loads HomeKit once, early, so the system's Home access prompt appears when the app opens
    /// rather than in the middle of a set. Never throws and never blocks the caller for long.
    public func preload() async {
        await waitForHomes()
        logger.log("home preload: \(self.manager.homes.count, privacy: .public) home(s)")
    }

    /// How many homes HomeKit returned. Zero means access was refused, the entitlement is missing,
    /// or the owner has no home on this device — the only signal HomeKit offers.
    public var homeCount: Int? { manager.homes.count }

    /// HomeKit loads homes asynchronously; wait for the first update instead of returning an empty
    /// list. The wait is bounded: a scene must never hang the workout that triggered it.
    private func waitForHomes() async {
        if homes.loaded || !manager.homes.isEmpty { return }
        await homes.wait(timeout: 4)
    }

    @objc nonisolated public func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in
            // One update satisfies every suspended caller. An empty home list is a valid result:
            // denied access or no configured home must not leave the UI or workout waiting.
            self.homes.markLoaded()
        }
    }
}

/// One-shot fan-out for the initial HomeKit load.
///
/// A stored continuation per caller cannot be overwritten by a second wait, and every waiter is
/// resumed exactly once. The loaded flag also closes the race where the delegate fired before a
/// caller suspended.
@MainActor
final class HomesWaiters {
    private(set) var loaded = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Waits for the first HomeKit update, or `timeout` seconds, whichever comes first. A manager
    /// that never calls back — a missing HomeKit entitlement, for instance — must not suspend the
    /// caller forever.
    func wait(timeout: TimeInterval) async {
        if loaded { return }
        await withCheckedContinuation { continuation in
            if loaded {
                continuation.resume()
                return
            }
            waiters.append(continuation)
            Task { @MainActor in
                try? await Task.sleep(
                    nanoseconds: UInt64(max(0, timeout) * 1_000_000_000)
                )
                self.markLoaded()
            }
        }
    }

    func markLoaded() {
        guard !loaded else { return }
        loaded = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
