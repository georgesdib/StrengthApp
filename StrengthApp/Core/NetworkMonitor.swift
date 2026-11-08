import Foundation
import Network

/// Reports network availability while the app is open. It intentionally has no background
/// execution: Phase 4 retries only on foreground, network recovery and explicit user action.
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "StrengthApp.network-monitor")
    private var wasAvailable: Bool?
    private let onAvailable: () -> Void

    init(onAvailable: @escaping () -> Void) {
        self.onAvailable = onAvailable
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let available = path.status == .satisfied
            let recovered = self.wasAvailable == false && available
            self.wasAvailable = available
            guard recovered else { return }
            DispatchQueue.main.async { self.onAvailable() }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
