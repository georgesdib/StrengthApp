import Foundation
import Network

/// Reports network changes while the app is open. It intentionally has no background
/// execution: Phase 4 retries and Home/Away switching only on foreground or network changes.
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "StrengthApp.network-monitor")
    private let onUpdate: () -> Void

    init(onUpdate: @escaping () -> Void) {
        self.onUpdate = onUpdate
        monitor.pathUpdateHandler = { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async { self.onUpdate() }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
