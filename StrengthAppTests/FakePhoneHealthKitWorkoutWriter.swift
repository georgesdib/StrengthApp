import Foundation
@testable import StrengthApp

@MainActor
final class FakePhoneHealthKitWorkoutWriter: PhoneHealthKitWorkoutWriting {
    struct Save: Equatable {
        let workoutID: String
        let startedAt: Date
        let endedAt: Date
    }

    private(set) var saves: [Save] = []

    func save(workoutID: String, startedAt: Date, endedAt: Date) async {
        saves.append(Save(workoutID: workoutID, startedAt: startedAt, endedAt: endedAt))
    }
}
