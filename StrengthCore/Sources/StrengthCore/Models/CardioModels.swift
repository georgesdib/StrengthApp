import Foundation

/// Payload for the authenticated cardio overview (C6b).
public struct CardioWeek: Decodable, Identifiable, Equatable {
    public var id: String { isoWeek }
    public let isoWeek: String
    public let workouts: Int
    public let totalMinutes: Double
    public let equivalentMinutes: Double
    public let moderateMinutes: Double
    public let vigorousMinutes: Double
    public let resistanceMinutes: Double
    public let unclassifiedMinutes: Double
}

public struct CardioRolling: Decodable, Equatable {
    public let totalMinutes: Double
    public let equivalentMinutes: Double
    public let moderateMinutes: Double
    public let vigorousMinutes: Double
    public let unclassifiedMinutes: Double
}

public struct CardioRecentWorkout: Decodable, Identifiable, Equatable {
    public let id: String
    public let activity: String
    public let startedAt: String
    public let minutes: Int
    public let source: String?
    public let hidden: Bool
}

public struct CardioSummaryBody: Decodable, Equatable {
    public let weeks: [CardioWeek]
    public let rolling: [String: CardioRolling]
    public let latestWorkoutAt: String?
}

public struct CardioActivityPayload: Decodable, Equatable {
    public let summary: CardioSummaryBody
    public let recent: [CardioRecentWorkout]
}
