import Foundation

/// Which configured server address should be used for the current network.
enum ServerRoute: String, Equatable {
    case home
    case away
}

struct ServerConfiguration: Equatable {
    var homeURL: String
    var awayURL: String
    var preferHome: Bool

    /// Choose Home when it is preferred and either not probed or reachable. Otherwise use
    /// Away; fall back to Home when Away is not configured. No SSID or location permission is
    /// involved, so personal development teams can sign the app.
    static func select(
        homeURL: String,
        awayURL: String,
        preferHome: Bool,
        homeReachable: Bool?
    ) -> (route: ServerRoute, url: String)? {
        let home = homeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let away = awayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if preferHome, !home.isEmpty {
            if homeReachable != false {
                return (.home, home)
            }
            return away.isEmpty ? (.home, home) : (.away, away)
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
