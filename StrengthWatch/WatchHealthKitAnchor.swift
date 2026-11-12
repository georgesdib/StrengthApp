import Foundation
import HealthKit
import StrengthCore

/// Owns the workout session and its live builder: liveness, heart rate, and the exactly-once save.
/// The save *rules* live in StrengthCore; this type only talks to HealthKit and maps its errors.
@MainActor
final class WatchHealthKitRecorder: NSObject, WatchLivenessAnchor, HealthKitSaving,
    HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {

    static let startTimeout: TimeInterval = 8

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var startGate: HealthKitStartGate?
    private var timeoutTask: Task<Void, Never>?

    /// Called with the current heart rate, or nil when it is unavailable.
    var onHeartRate: ((Int?) -> Void)?

    // MARK: - Liveness

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
        var share: Set<HKSampleType> = [HKObjectType.workoutType()]
        if let effort = HKQuantityType.quantityType(forIdentifier: .workoutEffortScore) {
            share.insert(effort)
        }
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
        session.delegate = self
        let builder = session.associatedWorkoutBuilder()
        builder.delegate = self
        builder.dataSource = HKLiveWorkoutDataSource(
            healthStore: healthStore, workoutConfiguration: configuration
        )
        self.session = session
        self.builder = builder
        self.startGate = HealthKitStartGate()
        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.startTimeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.failStart(LivenessError.notRunning)
            }
            session.startActivity(with: date)
            Task { [weak self] in
                do {
                    try await builder.beginCollection(at: date)
                    await self?.collectionBegan()
                } catch {
                    await self?.failStart(error)
                }
            }
        }
    }

    func end(at date: Date) async {
        finishStart(.failure(LivenessError.notRunning))
        session?.end()
        clearSession()
    }

    // MARK: - Saving

    /// Only true while a builder created for this session in this process can still finish.
    var hasLiveBuilder: Bool {
        builder != nil && session != nil
    }

    func hasWorkout(externalUUID: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForObjects(
                withMetadataKey: HKMetadataKeyExternalUUID,
                operatorType: .equalTo,
                value: externalUUID
            )
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: Self.classify(error))
                } else {
                    continuation.resume(returning: !(samples ?? []).isEmpty)
                }
            }
            healthStore.execute(query)
        }
    }

    func finishLiveWorkout(externalUUID: String, endedAt: Date) async throws {
        guard let builder else {
            throw HealthKitSaveFailure.definitive("The live workout builder is gone.")
        }
        do {
            try await builder.addMetadata([HKMetadataKeyExternalUUID: externalUUID])
            try await builder.endCollection(at: endedAt)
            guard let _ = try await builder.finishWorkout() else {
                throw HealthKitSaveFailure.transient("Health did not return a saved workout.")
            }
            session?.end()
            clearSession()
        } catch {
            // A finished builder cannot be reused; end the session so the next attempt takes the
            // minimal backdated path instead of retrying a dead builder.
            session?.end()
            clearSession()
            throw Self.classify(error)
        }
    }

    /// One backdated workout with the original dates and no samples (§12.3).
    func saveMinimalWorkout(
        externalUUID: String,
        startedAt: Date,
        endedAt: Date
    ) async throws {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .indoor
        let builder = HKWorkoutBuilder(
            healthStore: healthStore, configuration: configuration, device: .local()
        )
        do {
            try await builder.beginCollection(at: startedAt)
            try await builder.addMetadata([HKMetadataKeyExternalUUID: externalUUID])
            try await builder.endCollection(at: endedAt)
            guard let _ = try await builder.finishWorkout() else {
                throw HealthKitSaveFailure.transient("Health did not return a saved workout.")
            }
        } catch {
            throw Self.classify(error)
        }
    }

    /// Saves the effort sample against the workout found by UUID. Never creates a workout.
    func saveEffort(externalUUID: String, effort: Double) async throws {
        guard let workout = try await workout(externalUUID: externalUUID) else {
            throw HealthKitSaveFailure.transient("The workout is not available yet.")
        }
        guard let type = HKQuantityType.quantityType(forIdentifier: .workoutEffortScore) else {
            throw HealthKitSaveFailure.definitive("Workout effort is not supported here.")
        }
        do {
            let sample = HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: .appleEffortScore(), doubleValue: effort),
                start: workout.startDate,
                end: workout.endDate
            )
            try await healthStore.save(sample)
        } catch {
            throw Self.classify(error)
        }
    }

    func endWithoutSaving() async {
        session?.end()
        clearSession()
    }

    // MARK: - Private

    private func workout(externalUUID: String) async throws -> HKWorkout? {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForObjects(
                withMetadataKey: HKMetadataKeyExternalUUID,
                operatorType: .equalTo,
                value: externalUUID
            )
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: Self.classify(error))
                } else {
                    continuation.resume(returning: samples?.first as? HKWorkout)
                }
            }
            healthStore.execute(query)
        }
    }

    private static func classify(_ error: Error) -> HealthKitSaveFailure {
        if let failure = error as? HealthKitSaveFailure { return failure }
        let nsError = error as NSError
        guard nsError.domain == HKErrorDomain else {
            return .transient(nsError.localizedDescription)
        }
        guard let code = HKError.Code(rawValue: nsError.code) else {
            return .transient(nsError.localizedDescription)
        }
        switch code {
        case .errorAuthorizationDenied, .errorAuthorizationNotDetermined,
             .errorHealthDataUnavailable, .errorHealthDataRestricted,
             .errorInvalidArgument, .errorUserCanceled,
             .errorAnotherWorkoutSessionStarted, .errorUserExitedWorkoutSession,
             .errorRequiredAuthorizationDenied, .errorWorkoutActivityNotAllowed:
            return .definitive(nsError.localizedDescription)
        default:
            return .transient(nsError.localizedDescription)
        }
    }

    private func clearSession() {
        session = nil
        builder = nil
        onHeartRate?(nil)
    }

    private func collectionBegan() {
        guard var gate = startGate else { return }
        let outcome = gate.collectionStarted()
        startGate = gate
        applyStartOutcome(outcome)
    }

    private func sessionStarted() {
        guard var gate = startGate else { return }
        let outcome = gate.sessionStarted()
        startGate = gate
        applyStartOutcome(outcome)
    }

    private func applyStartOutcome(_ outcome: HealthKitStartGate.Outcome) {
        switch outcome {
        case .ready:
            finishStart(.success(()))
        case .failed:
            finishStart(.failure(LivenessError.notRunning))
            session?.end()
            clearSession()
        case .waiting:
            break
        }
    }

    private func failStart(_ error: Error) async {
        if var gate = startGate {
            _ = gate.failed(error.localizedDescription)
            startGate = gate
        }
        session?.end()
        clearSession()
        finishStart(.failure(error))
    }

    private func finishStart(_ result: Result<Void, Error>) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(with: result)
    }

    // MARK: - Delegates

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor [weak self] in
            switch toState {
            case .running:
                self?.sessionStarted()
            case .ended:
                await self?.failStart(LivenessError.notRunning)
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
            await self?.failStart(error)
        }
    }

    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        Task { @MainActor [weak self] in
            guard let self, let builder = self.builder else { return }
            guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate),
                  collectedTypes.contains(type) else { return }
            let unit = HKUnit.count().unitDivided(by: .minute())
            let bpm = builder.statistics(for: type)?
                .mostRecentQuantity()?
                .doubleValue(for: unit)
            self.onHeartRate?(bpm.map { Int($0.rounded()) })
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
