import Foundation

enum LivenessAuthorization: Equatable {
    case notDetermined
    case authorized
    case denied
    case unavailable
}

enum LivenessError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Health access is unavailable, so the watch cannot keep this session alive. Log on the iPhone instead."
    }
}

/// Keeps the app alive during a session (contract §11.2). HealthKit is required for a watch
/// session; the simulator runs with the no-op implementation so the state machine is testable.
@MainActor
protocol WatchLivenessAnchor {
    func authorizationStatus() async -> LivenessAuthorization
    func requestAuthorization() async -> LivenessAuthorization
    func begin(at date: Date) async throws
    func end(at date: Date) async
}

@MainActor
final class NoopLivenessAnchor: WatchLivenessAnchor {
    private(set) var isRunning = false

    func authorizationStatus() async -> LivenessAuthorization { .unavailable }
    func requestAuthorization() async -> LivenessAuthorization { .unavailable }

    func begin(at date: Date) async throws {
        isRunning = true
    }

    func end(at date: Date) async {
        isRunning = false
    }
}
