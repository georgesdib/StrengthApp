import Foundation
import Network
import StrengthCore

/// Which configured server address should be used for the current network.
enum ServerRoute: String, Equatable {
    case home
    case away
}

/// Which configured addresses the app can actually load.
///
/// App Transport Security permits cleartext `http://` only to local resources: unqualified host
/// names, `.local` names and IP address literals (`NSAllowsLocalNetworking` in
/// `Support/Info.plist`). Every other host needs `https://`; the system refuses the request
/// before a packet leaves the phone. Checking here turns a confusing failure at request time into
/// a warning while the owner is still editing the field.
enum ServerAddressPolicy {
    /// True when the address is cleartext HTTP to a host the system will refuse.
    static func cleartextIsBlocked(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "http",
              let host = components.host, !host.isEmpty else {
            return false
        }
        return !isLocalHost(host)
    }

    /// A local resource in the ATS sense: an IP literal, a `.local` name or an unqualified name.
    /// A host name with a public suffix is not, even when it currently resolves to a LAN address.
    static func isLocalHost(_ host: String) -> Bool {
        var name = host.lowercased()
        if name.hasPrefix("["), name.hasSuffix("]") {
            name = String(name.dropFirst().dropLast())
        }
        if name == "localhost" || name.hasSuffix(".local") { return true }
        if !name.contains(".") { return true }
        return IPv4Address(name) != nil || IPv6Address(name) != nil
    }
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
