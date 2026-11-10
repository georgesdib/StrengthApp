import Foundation
import StrengthCore

enum AppConfig {
    #if DEBUG
    /// Simulator/development convenience only. Release starts empty so a wrong default never
    /// reaches the owner's phone.
    static let defaultServerURL = "http://127.0.0.1:8000"
    #else
    static let defaultServerURL = ""
    #endif

    static var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return "\(version ?? "1.0") (\(build ?? "1"))"
    }
}

struct PairingDevice: Codable, Equatable {
    let deviceID: String
    let label: String
}

/// Non-secret phone-side state for the one watch paired with this phone. The watch token is
/// deliberately absent: it lives only in memory until the watch acknowledges it.
struct PairedWatch: Codable, Equatable {
    var deviceID: String
    var label: String
    var epoch: Int
    var ackEpoch: Int
    var configVersion: Int
    var revoked: Bool
    var lastAckAt: String?
}

/// Non-secret paired-device metadata. The token lives only in the Keychain.
final class PairedStore {
    private let defaults: UserDefaults
    private let serverURLKey = "ios.serverURL"
    private let homeServerURLKey = "ios.server.homeURL"
    private let awayServerURLKey = "ios.server.awayURL"
    private let preferHomeKey = "ios.server.preferHome"
    private let deviceKey = "ios.paired.device"
    private let watchConfigVersionKey = "ios.watch.configVersion"
    private let watchLinkKey = "ios.watch.link"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The address currently in use. Kept for compatibility with builds before the Home/Away
    /// split, and refreshed whenever the selected route changes.
    var serverURL: String? {
        get { defaults.string(forKey: serverURLKey) }
        set { defaults.setValue(newValue, forKey: serverURLKey) }
    }

    var homeServerURL: String? {
        get { defaults.string(forKey: homeServerURLKey) }
        set { defaults.setValue(newValue, forKey: homeServerURLKey) }
    }

    var awayServerURL: String? {
        get { defaults.string(forKey: awayServerURLKey) }
        set { defaults.setValue(newValue, forKey: awayServerURLKey) }
    }

    /// Home is preferred by default. Turning this off is the manual Away override; when it is
    /// on, the app selects Home only if that address answers a short reachability probe.
    var preferHome: Bool {
        get {
            guard defaults.object(forKey: preferHomeKey) != nil else { return true }
            return defaults.bool(forKey: preferHomeKey)
        }
        set { defaults.setValue(newValue, forKey: preferHomeKey) }
    }

    /// Existing installations used one server URL. Treat it as Home; Away stays empty so the
    /// old single-address behaviour is preserved until the owner adds an Away address.
    func migrateServerConfigurationIfNeeded() {
        let hadHome = defaults.object(forKey: homeServerURLKey) != nil
        if !hadHome, let legacy = serverURL, !legacy.isEmpty {
            homeServerURL = legacy
        }
        if defaults.object(forKey: watchConfigVersionKey) == nil {
            watchConfigVersion = 1
        }
        if !hadHome, homeServerURL != nil {
            _ = bumpWatchConfigVersion()
        }
    }

    /// Phone-local monotonic version for the watch's Home URL/config. It is independent of the
    /// server credential epoch and starts at 1 for a new install.
    var watchConfigVersion: Int {
        get {
            let value = defaults.integer(forKey: watchConfigVersionKey)
            return value > 0 ? value : 1
        }
        set { defaults.set(max(1, newValue), forKey: watchConfigVersionKey) }
    }

    @discardableResult
    func bumpWatchConfigVersion() -> Int {
        let next = watchConfigVersion + 1
        watchConfigVersion = next
        return next
    }

    var watchLink: PairedWatch? {
        get {
            guard let data = defaults.data(forKey: watchLinkKey) else { return nil }
            return try? JSONDecoder().decode(PairedWatch.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: watchLinkKey)
                return
            }
            defaults.set(data, forKey: watchLinkKey)
        }
    }

    func clearWatchLink() {
        defaults.removeObject(forKey: watchLinkKey)
    }

    var serverConfiguration: ServerConfiguration {
        ServerConfiguration(
            homeURL: homeServerURL ?? "",
            awayURL: awayServerURL ?? "",
            preferHome: preferHome
        )
    }

    var device: PairingDevice? {
        get {
            guard let data = defaults.data(forKey: deviceKey) else { return nil }
            return try? JSONDecoder().decode(PairingDevice.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: deviceKey)
                return
            }
            defaults.set(data, forKey: deviceKey)
        }
    }
}
