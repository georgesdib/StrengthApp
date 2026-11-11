import Foundation
import HealthKit

/// Starts and ends a real `HKWorkoutSession` for liveness only. Phase 6.3 saves no workout: the
/// builder, heart rate and the exactly-once save belong to 6.5.
@MainActor
final class WatchHealthKitAnchor: WatchLivenessAnchor {
    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?

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

    func begin(at date: Date) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw LivenessError.unavailable }
        guard session == nil else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .indoor
        let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
        session.startActivity(with: date)
        self.session = session
    }

    func end(at date: Date) async {
        session?.end()
        session = nil
    }
}
