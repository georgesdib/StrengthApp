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

public struct CardioTimeInZone: Decodable, Equatable {
    public let eligibleWorkouts: Int
    public let coverageShare: Double
    public let moderateMinutes: Double
    public let vigorousMinutes: Double
    public let equivalentMinutes: Double
    public let windowDays: Int

    private struct Minutes: Decodable {
        let moderate: Double
        let vigorous: Double
    }

    private struct Window: Decodable {
        let days: Int
    }

    private enum CodingKeys: String, CodingKey {
        case eligibleWorkouts = "eligible_workouts"
        case coverageShare = "coverage_share"
        case equivalentMinutes = "equivalent_minutes"
        case minutes, window
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eligibleWorkouts = try container.decode(Int.self, forKey: .eligibleWorkouts)
        coverageShare = try container.decode(Double.self, forKey: .coverageShare)
        equivalentMinutes = try container.decode(Double.self, forKey: .equivalentMinutes)
        let minutes = try container.decode(Minutes.self, forKey: .minutes)
        moderateMinutes = minutes.moderate
        vigorousMinutes = minutes.vigorous
        windowDays = try container.decode(Window.self, forKey: .window).days
    }
}

public struct CardioAssessment: Decodable, Equatable {
    public let timeInZone: CardioTimeInZone?

    enum CodingKeys: String, CodingKey {
        case timeInZone = "time_in_zone"
    }
}

public struct CardioActivityPayload: Decodable, Equatable {
    public let summary: CardioSummaryBody
    public let recent: [CardioRecentWorkout]
    public let assessment: CardioAssessment?
}
