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

/// Runs HomeKit scenes. Behind a protocol so the automation is testable without a home.
@MainActor
public protocol SceneRunning: AnyObject {
    func scenes() async -> [SceneSelection]
    func run(_ selection: SceneSelection) async -> Bool
}

/// Live HomeKit executor. Best-effort: a denied authorisation, a deleted home or a missing scene
/// returns `false` and never throws into the workout path.
@MainActor
public final class HomeKitSceneRunner: NSObject, SceneRunning {
    public static let shared = HomeKitSceneRunner()

    private let manager = HMHomeManager()
    private var loadedHomes = false
    private var homesContinuation: CheckedContinuation<Void, Never>?
    private let logger = Logger(
        subsystem: "com.georgesdibpersonalteam.StrengthApp",
        category: "automation"
    )

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
            logger.error("scene home not found; skipping")
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

    /// HomeKit loads homes asynchronously; wait for the first update instead of returning an empty list.
    private func waitForHomes() async {
        if loadedHomes || !manager.homes.isEmpty { return }
        await withCheckedContinuation { continuation in
            homesContinuation = continuation
        }
    }

    nonisolated public func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in
            self.loadedHomes = true
            self.homesContinuation?.resume()
            self.homesContinuation = nil
        }
    }
}
