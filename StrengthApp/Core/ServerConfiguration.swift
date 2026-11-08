import Foundation

/// Which configured server address should be used for the current network.
enum ServerRoute: String, Equatable {
    case home
    case away
}

struct ServerConfiguration: Equatable {
    var homeURL: String
    var awayURL: String
    var homeWiFi: String

    /// Home wins only on an exact Wi-Fi name match. Otherwise Away is used when configured;
    /// Home remains the fallback so a single-address setup keeps working offline.
    static func select(
        homeURL: String,
        awayURL: String,
        homeWiFi: String,
        currentSSID: String?
    ) -> (route: ServerRoute, url: String)? {
        let home = homeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let away = awayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let wifi = homeWiFi.trimmingCharacters(in: .whitespacesAndNewlines)
        if !home.isEmpty, !wifi.isEmpty, currentSSID == wifi {
            return (.home, home)
        }
        if !away.isEmpty {
            return (.away, away)
        }
        if !home.isEmpty {
            return (.home, home)
        }
        return nil
    }
}
