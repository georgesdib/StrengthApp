import Foundation

public enum ExecutionEventType: String, Codable, CaseIterable {
    case setStarted = "set_started"
    case setCompleted = "set_completed"
    case restStarted = "rest_started"
    case restCompleted = "rest_completed"
    case restSkipped = "rest_skipped"
    case restExtended = "rest_extended"
    case exerciseStarted = "exercise_started"
    case exerciseCompleted = "exercise_completed"
    case workoutPaused = "workout_paused"
    case workoutResumed = "workout_resumed"
}

public struct ExecutionEvent: Codable, Equatable, Identifiable {
    public let eventId: String
    public let eventType: ExecutionEventType
    public let occurredAt: String
    public let planItemIndex: Int?
    public let setId: Int?
    public let localSetId: String?
    public let payload: [String: JSONValue]?

    public var id: String { eventId }

    public init(
        eventId: String = UUID().uuidString.lowercased(),
        eventType: ExecutionEventType,
        occurredAt: String = ExecutionEvent.nowISO(),
        planItemIndex: Int? = nil,
        setId: Int? = nil,
        localSetId: String? = nil,
        payload: [String: JSONValue]? = nil
    ) {
        self.eventId = eventId
        self.eventType = eventType
        self.occurredAt = occurredAt
        self.planItemIndex = planItemIndex
        self.setId = setId
        self.localSetId = localSetId
        self.payload = payload
    }

    public static func nowISO() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

public struct ExecutionEventsRequest: Encodable {
    public let events: [ExecutionEvent]

    public init(events: [ExecutionEvent]) {
        self.events = events
    }
}

public struct ExecutionEventsResponse: Decodable {
    public let workoutId: String
    public let accepted: [String]
    public let duplicates: [String]
    public let receivedAt: String
}

public struct ExecutionAnalyticsResponse: Decodable {
    public let workoutId: String
    public let status: String
    public let startedAt: String
    public let endedAt: String?
    public let totalElapsedS: Double
    public let events: [ExecutionAnalyticsEvent]
    public let sets: [ExecutionAnalyticsSet]
    public let rests: [ExecutionAnalyticsRest]
    public let exercises: [ExecutionAnalyticsExercise]
    public let summary: ExecutionAnalyticsSummary
    public let dataQuality: ExecutionAnalyticsQuality
}

public struct ExecutionAnalyticsEvent: Decodable, Identifiable {
    public let eventId: String
    public let eventType: String
    public let occurredAt: String
    public let planItemIndex: Int?
    public let setId: Int?
    public let localSetId: String?
    public let payload: [String: JSONValue]?

    public var id: String { eventId }
}

public struct ExecutionAnalyticsSet: Decodable, Identifiable {
    public let setId: Int?
    public let localSetId: String?
    public let planItemIndex: Int?
    public let startedAt: String
    public let completedAt: String
    public let durationS: Double

    public var id: String { localSetId ?? "set-\(setId ?? 0)" }
}

public struct ExecutionAnalyticsRest: Decodable, Identifiable {
    public let startedAt: String
    public let endedAt: String
    public let prescribedRestS: Double?
    public let actualRestS: Double
    public let outcome: String
    public let deviationS: Double?
    public let deviationPct: Double?
    public let planItemIndex: Int?

    public var id: String { "\(startedAt)-\(endedAt)" }
}

public struct ExecutionAnalyticsExercise: Decodable, Identifiable {
    public let planItemIndex: Int?
    public let startedAt: String
    public let endedAt: String
    public let durationS: Double

    public var id: String { "\(startedAt)-\(endedAt)" }
}

public struct ExecutionAnalyticsSummary: Decodable {
    public let activeLiftingS: Double
    public let recordedRecoveryS: Double
    public let exerciseTransitionS: Double
    public let unclassifiedS: Double
    public let totalElapsedS: Double
}

public struct ExecutionAnalyticsQuality: Decodable {
    public let eventCount: Int
    public let setsWithDuration: Int
    public let restsWithActual: Int
    public let restsWithoutPrescribed: Int
    public let workoutHasEnd: Bool
    public let setStartedEvents: Int?
    public let setCompletedEvents: Int?
    public let restStartedEvents: Int?
    public let restEndedEvents: Int?
}
