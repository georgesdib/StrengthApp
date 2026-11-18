import Foundation

/// The build identity the install script stamps into Info.plist (UTC time, commit, dirty flag).
/// It is written to user defaults at launch so the installed build can be identified from the
/// device without reading the app bundle.
public enum BuildStamp {
    public static let defaultsKey = "app.buildStamp"

    public static var current: String {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "StrengthBuildStamp") as? String,
              !raw.isEmpty, !raw.contains("$(") else { return "unknown" }
        return raw
    }

    /// Called once per launch; keeps the value current after an install.
    public static func record(defaults: UserDefaults = .standard) {
        defaults.set(current, forKey: defaultsKey)
    }
}
