import Foundation

enum ExecutionEventType: String, Codable, CaseIterable {
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

struct ExecutionEvent: Codable, Equatable, Identifiable {
    let eventId: String
    let eventType: ExecutionEventType
    let occurredAt: String
    let planItemIndex: Int?
    let setId: Int?
    let localSetId: String?
    let payload: [String: JSONValue]?

    var id: String { eventId }

    init(
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

    static func nowISO() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

struct ExecutionEventsRequest: Encodable {
    let events: [ExecutionEvent]
}

struct ExecutionEventsResponse: Decodable {
    let workoutId: String
    let accepted: [String]
    let duplicates: [String]
    let receivedAt: String
}

struct ExecutionAnalyticsResponse: Decodable {
    let workoutId: String
    let status: String
    let startedAt: String
    let endedAt: String?
    let totalElapsedS: Double
    let events: [ExecutionAnalyticsEvent]
    let sets: [ExecutionAnalyticsSet]
    let rests: [ExecutionAnalyticsRest]
    let exercises: [ExecutionAnalyticsExercise]
    let summary: ExecutionAnalyticsSummary
    let dataQuality: ExecutionAnalyticsQuality
}

struct ExecutionAnalyticsEvent: Decodable, Identifiable {
    let eventId: String
    let eventType: String
    let occurredAt: String
    let planItemIndex: Int?
    let setId: Int?
    let localSetId: String?
    let payload: [String: JSONValue]?

    var id: String { eventId }
}

struct ExecutionAnalyticsSet: Decodable, Identifiable {
    let setId: Int?
    let localSetId: String?
    let planItemIndex: Int?
    let startedAt: String
    let completedAt: String
    let durationS: Double

    var id: String { localSetId ?? "set-\(setId ?? 0)" }
}

struct ExecutionAnalyticsRest: Decodable, Identifiable {
    let startedAt: String
    let endedAt: String
    let prescribedRestS: Double?
    let actualRestS: Double
    let outcome: String
    let deviationS: Double?
    let deviationPct: Double?
    let planItemIndex: Int?

    var id: String { "\(startedAt)-\(endedAt)" }
}

struct ExecutionAnalyticsExercise: Decodable, Identifiable {
    let planItemIndex: Int?
    let startedAt: String
    let endedAt: String
    let durationS: Double

    var id: String { "\(startedAt)-\(endedAt)" }
}

struct ExecutionAnalyticsSummary: Decodable {
    let activeLiftingS: Double
    let recordedRecoveryS: Double
    let exerciseTransitionS: Double
    let unclassifiedS: Double
    let totalElapsedS: Double
}

struct ExecutionAnalyticsQuality: Decodable {
    let eventCount: Int
    let setsWithDuration: Int
    let restsWithActual: Int
    let restsWithoutPrescribed: Int
    let workoutHasEnd: Bool
    let setStartedEvents: Int?
    let setCompletedEvents: Int?
    let restStartedEvents: Int?
    let restEndedEvents: Int?
}
