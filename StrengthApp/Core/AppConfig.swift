import Foundation

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

/// Non-secret paired-device metadata. The token lives only in the Keychain.
final class PairedStore {
    private let defaults: UserDefaults
    private let serverURLKey = "ios.serverURL"
    private let homeServerURLKey = "ios.server.homeURL"
    private let awayServerURLKey = "ios.server.awayURL"
    private let preferHomeKey = "ios.server.preferHome"
    private let deviceKey = "ios.paired.device"

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
        guard defaults.object(forKey: homeServerURLKey) == nil else { return }
        if let legacy = serverURL, !legacy.isEmpty {
            homeServerURL = legacy
        }
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
