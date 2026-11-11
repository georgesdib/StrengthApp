import Foundation

/// The watch's view of the home server (contract §10.7).
///
/// "Cellular available" is not online: the server runs on the home LAN, so only a successful
/// home-server call may mark a session online. There is deliberately no "reachable" input on
/// this type; a path monitor or a cellular radio can never make the watch online.
public enum HomeNetworkState: Equatable, Sendable {
    case unknown
    case online(host: String)
    case offline

    public var isOnline: Bool {
        if case .online = self { return true }
        return false
    }

    public var host: String? {
        if case .online(let host) = self { return host }
        return nil
    }
}

/// Transitions for `HomeNetworkState`, kept separate so the rule is testable without a network.
public struct HomeNetworkPolicy: Equatable, Sendable {
    public private(set) var state: HomeNetworkState

    public init(state: HomeNetworkState = .unknown) {
        self.state = state
    }

    /// A successful home-server call is the only event that marks the session online.
    @discardableResult
    public mutating func succeeded(host: String) -> HomeNetworkState {
        state = .online(host: host)
        return state
    }

    /// A failed home-server call marks the session offline, from any prior state.
    @discardableResult
    public mutating func failed() -> HomeNetworkState {
        state = .offline
        return state
    }
}
