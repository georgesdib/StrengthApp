import Foundation
import StrengthCore

/// REST-backed facts for the chat tools. Records every envelope so the answer can be grounded.
final class ChatToolbox: ChatFactsProviding, @unchecked Sendable {
    private let client: IOSAPIClient
    private let session: IOSSession
    private let lock = NSLock()
    private var envelopes: [IntelligenceEnvelope] = []
    private var sources: Set<String> = []

    init(client: IOSAPIClient, session: IOSSession) {
        self.client = client
        self.session = session
    }

    var recordedEnvelopes: [IntelligenceEnvelope] {
        lock.lock(); defer { lock.unlock() }
        return envelopes
    }

    var recordedSources: [String] {
        lock.lock(); defer { lock.unlock() }
        return sources.sorted()
    }

    func resetRecord() {
        lock.lock(); defer { lock.unlock() }
        envelopes = []
        sources = []
    }

    private func record(_ envelope: IntelligenceEnvelope, source: String) -> String {
        lock.lock()
        envelopes.append(envelope)
        sources.insert(source)
        lock.unlock()
        return NarrativeContext.projectionText(envelope)
    }

    func trainingOverview(asOf: String?, windowWeeks: Int) async throws -> String {
        try record(
            try await client.overview(session: session, asOf: asOf, windowWeeks: windowWeeks),
            source: "overview"
        )
    }

    func exerciseProgression(exerciseID: String, windowDays: Int) async throws -> String {
        try record(
            try await client.progression(
                session: session, exerciseID: exerciseID, windowDays: windowDays
            ),
            source: "progression"
        )
    }

    func weeklyReview(weekEnd: String?) async throws -> String {
        try record(
            try await client.weeklyReview(session: session, weekEnd: weekEnd),
            source: "weekly review"
        )
    }

    func sessionDetails(workoutID: String) async throws -> String {
        // An explicit id must resolve to that exact workout. A failed lookup is surfaced, never
        // silently replaced by another session.
        if !workoutID.isEmpty {
            let envelope = try await client.intelligenceSessionDetails(
                session: session, workoutID: workoutID
            )
            return record(envelope, source: "session details")
        }
        let history = try await client.history(session: session, limit: 1)
        guard let latest = history.sessions.first else {
            return "There are no completed sessions yet."
        }
        let envelope = try await client.intelligenceSessionDetails(
            session: session, sessionID: latest.sessionId
        )
        return record(envelope, source: "session details")
    }

    func readinessStatus(from: String, to: String) async throws -> String {
        let (start, end) = Self.window(from: from, to: to)
        return try record(
            try await client.readinessHistory(
                session: session, from: start, to: end, fields: ["score"]
            ),
            source: "readiness"
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
