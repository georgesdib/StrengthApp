import Foundation

/// UserDefaults keys shared by the app and an App Intent that runs in its process. Keep the
/// strings stable: they are part of the existing on-device state, not a new contract.
public enum SharedDefaultsKeys {
    /// JSON-encoded paired-watch metadata written by the app's `PairedStore.watchLink`.
    public static let watchLink = "ios.watch.link"
}
