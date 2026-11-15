import Foundation
import StrengthCore

/// REST-backed facts for the chat tools. Records every envelope so the answer can be grounded.
final class ChatToolbox: ChatFactsProviding, PlanFactsProviding, @unchecked Sendable {
    private let client: IOSAPIClient
    private let session: IOSSession
    private let lock = NSLock()
    private var envelopes: [IntelligenceEnvelope] = []
    private var sources: Set<String> = []
    private var outputs: [ChatToolOutput] = []

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

    var recordedOutputs: [ChatToolOutput] {
        lock.lock(); defer { lock.unlock() }
        return outputs
    }

    func resetRecord() {
        lock.lock(); defer { lock.unlock() }
        envelopes = []
        sources = []
        outputs = []
    }

    private func record(_ envelope: IntelligenceEnvelope, source: String) -> String {
        let text = ["prescription", "adherence", "programme"].contains(source)
            ? PlanProjection.text(envelope)
            : NarrativeContext.projectionText(envelope)
        lock.lock()
        envelopes.append(envelope)
        sources.insert(source)
        outputs.append(ChatToolOutput(source: source, text: text))
        lock.unlock()
        return text
    }

    func trainingOverview(asOf: String?, windowWeeks: Int) async throws -> String {
        record(
            try await client.overview(session: session, asOf: asOf, windowWeeks: windowWeeks),
            source: "overview"
        )
    }

    func exerciseProgression(exerciseID: String, windowDays: Int) async throws -> String {
        record(
            try await client.progression(
                session: session, exerciseID: exerciseID, windowDays: windowDays
            ),
            source: "progression"
        )
    }

    func weeklyReview(weekEnd: String?) async throws -> String {
        record(
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

    func prescription(query: String) async throws -> String {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let envelope: IntelligenceEnvelope
        if value.isEmpty || value.lowercased() == "today" {
            envelope = try await client.prescription(session: session)
        } else if let date = PlanQuery.isoDate(from: value) {
            envelope = try await client.prescription(session: session, forDate: date)
        } else {
            envelope = try await client.prescription(session: session, prescriptionID: value)
        }
        return record(envelope, source: "prescription")
    }

    func programmeSummary(query: String) async throws -> String {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let envelope = try await client.programmeSummary(
            session: session,
            asOf: PlanQuery.isoDate(from: value),
            blockWeeks: 4
        )
        return record(envelope, source: "programme")
    }

    func adherence(query: String) async throws -> String {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let weeks = Int(value) {
            return record(
                try await client.adherence(session: session, weeks: weeks),
                source: "adherence"
            )
        }
        return record(
            try await client.adherence(
                session: session,
                asOf: PlanQuery.isoDate(from: value),
                weeks: 12
            ),
            source: "adherence"
        )
    }

    func readinessStatus(from: String, to: String) async throws -> String {
        let (start, end) = Self.window(from: from, to: to)
        return record(
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
