import Foundation
import StrengthCore

/// Bridges the five capability tools to the app's paired REST session.
final class RESTIntelligenceProvider: IntelligenceCapabilityProviding, @unchecked Sendable {
    private let client: IOSAPIClient
    private let session: IOSSession

    init(client: IOSAPIClient, session: IOSSession) {
        self.client = client
        self.session = session
    }

    func trainingOverview(asOf: String?, windowWeeks: Int) async throws -> String {
        NarrativeContext.projectionText(
            try await client.overview(session: session, asOf: asOf, windowWeeks: windowWeeks)
        )
    }

    func exerciseProgression(exerciseID: String, windowDays: Int) async throws -> String {
        NarrativeContext.projectionText(
            try await client.progression(
                session: session, exerciseID: exerciseID, windowDays: windowDays
            )
        )
    }

    func weeklyReview(weekEnd: String?) async throws -> String {
        NarrativeContext.projectionText(
            try await client.weeklyReview(session: session, weekEnd: weekEnd)
        )
    }

    func sessionDetails(workoutID: String) async throws -> String {
        guard !workoutID.isEmpty else {
            return "No workout was specified, so no session detail is available."
        }
        return NarrativeContext.projectionText(
            try await client.intelligenceSessionDetails(session: session, workoutID: workoutID)
        )
    }

    func readinessStatus(from: String, to: String) async throws -> String {
        let (start, end) = Self.window(from: from, to: to)
        return NarrativeContext.projectionText(
            try await client.readinessHistory(session: session, from: start, to: end)
        )
    }

    private static func window(from: String, to: String) -> (String, String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let end = to.isEmpty ? Date() : (formatter.date(from: to) ?? Date())
        let start = from.isEmpty
            ? Calendar(identifier: .gregorian).date(byAdding: .day, value: -6, to: end) ?? end
            : (formatter.date(from: from) ?? end)
        return (formatter.string(from: start), formatter.string(from: end))
    }
}
