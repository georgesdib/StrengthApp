import Foundation
import HealthKit
import OSLog

/// The phone's one HealthKit writer for a finished session (D11/C3).
///
/// The phone and the watch may both save. This writer never deletes, merges or "corrects" a
/// HealthKit record, keeps no pending state and does not feed HealthKit identity back into the
/// server merge. A denial or an unavailable store is reported to the log only; the workout is
/// already committed to the server.
@MainActor
protocol PhoneHealthKitWorkoutWriting: AnyObject {
    func save(workoutID: String, startedAt: Date, endedAt: Date) async
}

@MainActor
final class PhoneHealthKitWorkoutWriter: PhoneHealthKitWorkoutWriting {
    private let store: HKHealthStore
    private let logger = Logger(subsystem: "StrengthApp", category: "healthkit-writer")
    private var savedWorkoutIDs: Set<String> = []

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    func save(workoutID: String, startedAt: Date, endedAt: Date) async {
        guard HKHealthStore.isHealthDataAvailable(), endedAt > startedAt else { return }
        guard !savedWorkoutIDs.contains(workoutID) else { return }

        let status = store.authorizationStatus(for: HKObjectType.workoutType())
        guard status == .sharingAuthorized else {
            logger.notice(
                "phone HealthKit workout not saved: write access is not granted for \(workoutID, privacy: .public)"
            )
            return
        }

        do {
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .traditionalStrengthTraining
            configuration.locationType = .unknown
            let builder = HKWorkoutBuilder(
                healthStore: store,
                configuration: configuration,
                device: .local()
            )
            try await builder.beginCollection(at: startedAt)
            try await builder.addMetadata([HKMetadataKeyExternalUUID: workoutID])
            try await builder.endCollection(at: endedAt)
            guard try await builder.finishWorkout() != nil else {
                throw PhoneHealthKitWriteError.noWorkout
            }
            savedWorkoutIDs.insert(workoutID)
        } catch {
            // No retry loop, no pending marker: the server record is the training data.
            logger.notice(
                "phone HealthKit workout not saved for \(workoutID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

}

enum PhoneHealthKitWriteError: LocalizedError {
    case noWorkout

    var errorDescription: String? {
        switch self {
        case .noWorkout: return "Health did not return a saved workout."
        }
    }
}
