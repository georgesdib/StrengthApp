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
        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.startTimeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finishStart(.failure(LivenessError.notRunning))
            }
            session.startActivity(with: date)
            Task { [weak self] in
                do {
                    try await builder.beginCollection(at: date)
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

    var hasLiveBuilder: Bool {
        builder != nil && session != nil
    }

    func hasWorkout(externalUUID: String) async -> Bool {
        await withCheckedContinuation { continuation in
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
            ) { _, samples, _ in
                continuation.resume(returning: !(samples ?? []).isEmpty)
            }
            healthStore.execute(query)
        }
    }

    func finishLiveWorkout(
        externalUUID: String,
        endedAt: Date,
        effort: Double?
    ) async throws {
        guard let builder else {
            throw HealthKitSaveFailure.definitive("The live workout builder is gone.")
        }
        try await save(
            builder: builder,
            externalUUID: externalUUID,
            endedAt: endedAt,
            effort: effort
        )
        session?.end()
        clearSession()
    }

    /// One backdated workout with the original dates and no samples (§12.3).
    func saveMinimalWorkout(
        externalUUID: String,
        startedAt: Date,
        endedAt: Date,
        effort: Double?
    ) async throws {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .indoor
        let builder = HKWorkoutBuilder(
            healthStore: healthStore, configuration: configuration, device: .local()
        )
        do {
            try await builder.beginCollection(at: startedAt)
        } catch {
            throw Self.classify(error)
        }
        try await save(
            builder: builder,
            externalUUID: externalUUID,
            endedAt: endedAt,
            effort: effort
        )
    }

    func endWithoutSaving() async {
        session?.end()
        clearSession()
    }

    // MARK: - Private

    private func save(
        builder: HKWorkoutBuilder,
        externalUUID: String,
        endedAt: Date,
        effort: Double?
    ) async throws {
        do {
            try await builder.addMetadata([
                HKMetadataKeyExternalUUID: externalUUID,
            ])
            try await builder.endCollection(at: endedAt)
            let workout = try await builder.finishWorkout()
            if let effort, let workout {
                await saveEffort(effort, workout: workout)
            }
        } catch {
            throw Self.classify(error)
        }
    }

    /// Effort is additional data; failing to store it must not invalidate the workout.
    private func saveEffort(_ effort: Double, workout: HKWorkout) async {
        guard let type = HKQuantityType.quantityType(forIdentifier: .workoutEffortScore) else {
            return
        }
        let sample = HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: .appleEffortScore(), doubleValue: effort),
            start: workout.startDate,
            end: workout.endDate
        )
        try? await healthStore.save(sample)
    }

    private static func classify(_ error: Error) -> HealthKitSaveFailure {
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

    private func finishStart(_ result: Result<Void, Error>) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(with: result)
    }

    private func failStart(_ error: Error) async {
        finishStart(.failure(error))
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
