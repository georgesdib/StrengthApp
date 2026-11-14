import Foundation
import Network
import StrengthCore

/// Reports meaningful network changes while the app is open. It intentionally has no
/// background execution: Home/Away selection and Phase 4 retries only run on foreground or
/// network changes. Repeated callbacks with the same effective path are ignored — otherwise an
/// unreachable Home server behind Tailscale can make the settings page look like it is
/// continuously probing.
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "StrengthApp.network-monitor")
    private let onUpdate: () -> Void
    private var lastSignature: String?

    init(onUpdate: @escaping () -> Void) {
        self.onUpdate = onUpdate
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let signature = Self.signature(for: path)
            guard signature != self.lastSignature else { return }
            self.lastSignature = signature
            DispatchQueue.main.async { self.onUpdate() }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    private static func signature(for path: NWPath) -> String {
        let interfaces = path.availableInterfaces
            .map { String(describing: $0.type) }
            .sorted()
            .joined(separator: ",")
        return [
            String(describing: path.status),
            "\(path.isExpensive)",
            "\(path.isConstrained)",
            "\(path.supportsDNS)",
            "\(path.supportsIPv4)",
            "\(path.supportsIPv6)",
            interfaces,
        ].joined(separator: "|")
    }
}
