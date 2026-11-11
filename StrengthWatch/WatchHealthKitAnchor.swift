import Foundation
import HealthKit

/// Starts and ends a real `HKWorkoutSession` for liveness only, and waits for the session to
/// actually reach `.running` before the app may start a server workout. Phase 6.3 saves no
/// workout: the builder, heart rate and the exactly-once save belong to 6.5.
@MainActor
final class WatchHealthKitAnchor: NSObject, WatchLivenessAnchor, HKWorkoutSessionDelegate {
    static let startTimeout: TimeInterval = 8

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?

    func authorizationStatus() async -> LivenessAuthorization {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        switch healthStore.authorizationStatus(for: HKObjectType.workoutType()) {
        case .sharingAuthorized: return .authorized
        case .sharingDenied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    func requestAuthorization() async -> LivenessAuthorization {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        var read: Set<HKObjectType> = []
        if let heartRate = HKQuantityType.quantityType(forIdentifier: .heartRate) {
            read.insert(heartRate)
        }
        do {
            try await healthStore.requestAuthorization(toShare: share, read: read)
        } catch {
            return .denied
        }
        return await authorizationStatus()
    }

    /// Starts the session and resolves only once HealthKit reports it running. A session that
    /// never runs is a hard start failure: without it the app cannot be relied on to stay alive.
    func begin(at date: Date) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw LivenessError.unavailable }
        guard session == nil else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .indoor
        let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
        session.delegate = self
        self.session = session
        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.startTimeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finishStart(.failure(LivenessError.notRunning))
            }
            session.startActivity(with: date)
        }
    }

    func end(at date: Date) async {
        finishStart(.failure(LivenessError.notRunning))
        session?.end()
        session = nil
    }

    private func finishStart(_ result: Result<Void, Error>) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(with: result)
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor [weak self] in
            switch toState {
            case .running:
                self?.finishStart(.success(()))
            case .ended:
                self?.finishStart(.failure(LivenessError.notRunning))
            default:
                break
            }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.finishStart(.failure(error))
        }
    }
}
