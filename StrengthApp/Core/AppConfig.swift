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
    private let deviceKey = "ios.paired.device"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var serverURL: String? {
        get { defaults.string(forKey: serverURLKey) }
        set { defaults.setValue(newValue, forKey: serverURLKey) }
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
