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
/// The shipped `NSAllowsLocalNetworking` policy is narrower than "any IP address": measured on
/// the iOS 27.2 runtime, cleartext `http://` loads to private, loopback and link-local addresses
/// and to `.local` or single-word names, and is refused with -1022 for public addresses and for
/// CGNAT ranges such as Tailscale's 100.64.0.0/10. Checking here turns a confusing failure at
/// request time into a warning while the owner is still editing the field.
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

    /// A local resource in the ATS sense: a private, loopback or link-local IP literal, a
    /// `.local` name or an unqualified name. A host name with a public suffix is not one, even
    /// when it currently resolves to a LAN address.
    static func isLocalHost(_ host: String) -> Bool {
        var name = host.lowercased()
        if name.hasPrefix("["), name.hasSuffix("]") {
            name = String(name.dropFirst().dropLast())
        }
        if let address = IPv4Address(name) {
            let bytes = Array(address.rawValue)
            guard bytes.count == 4 else { return false }
            switch bytes[0] {
            case 10, 127: return true
            case 172: return (16...31).contains(bytes[1])
            case 192: return bytes[1] == 168
            case 169: return bytes[1] == 254
            default: return false
            }
        }
        if let address = IPv6Address(name) {
            let bytes = Array(address.rawValue)
            guard bytes.count == 16 else { return false }
            if bytes.allSatisfy({ $0 == 0 }) { return false }
            if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }
            if (bytes[0] & 0xfe) == 0xfc { return true }
            if bytes[0] == 0xfe, (bytes[1] & 0xc0) == 0x80 { return true }
            return false
        }
        if name == "localhost" || name.hasSuffix(".local") { return true }
        return !name.contains(".")
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
