import XCTest
import StrengthCore

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class StubDeepSeekAPI: DeepSeekCompleting, @unchecked Sendable {
    var responses: [DeepSeekChatResult]
    var error: Error?
    private(set) var calls: [[DeepSeekMessage]] = []

    init(responses: [DeepSeekChatResult], error: Error? = nil) {
        self.responses = responses
        self.error = error
    }

    func complete(messages: [DeepSeekMessage], tools: [DeepSeekTool]) async throws -> DeepSeekChatResult {
        calls.append(messages)
        if let error { throw error }
        return responses.removeFirst()
    }

    func validateKey() async throws {}
}

private final class StubFacts: ChatFactsProviding, PlanFactsProviding, @unchecked Sendable {
    private let envelope: IntelligenceEnvelope

    init(envelope: IntelligenceEnvelope) {
        self.envelope = envelope
    }

    var recordedEnvelopes: [IntelligenceEnvelope] = []
    var recordedSources: [String] = []
    var planErrors: [String: Error] = [:]
    var planText = "prescription facts"
    func resetRecord() {
        recordedEnvelopes = []
        recordedSources = []
    }

    private func record() -> String {
        recordedEnvelopes.append(envelope)
        recordedSources.append("weekly review")
        return NarrativeContext.projectionText(envelope)
    }

    private func recordPlan(_ source: String) -> String {
        recordedEnvelopes.append(envelope)
        recordedSources.append(source)
        return planText
    }

    func prescription(query: String) async throws -> String {
        if let error = planErrors["prescription"] { throw error }
        return recordPlan("prescription")
    }
    func programmeSummary(query: String) async throws -> String {
        if let error = planErrors["programme_summary"] { throw error }
        return recordPlan("programme")
    }
    func adherence(query: String) async throws -> String {
        if let error = planErrors["adherence"] { throw error }
        return recordPlan("adherence")
    }

    func trainingOverview(asOf: String?, windowWeeks: Int) async throws -> String { record() }
    func exerciseProgression(exerciseID: String, windowDays: Int) async throws -> String { record() }
    func weeklyReview(weekEnd: String?) async throws -> String { record() }
    func sessionDetails(workoutID: String) async throws -> String { record() }
    func readinessStatus(from: String, to: String) async throws -> String { record() }
}

@MainActor
final class DeepSeekChatTests: XCTestCase {
    private let envelopeJSON = """
    {
      "schema_version": "intelligence.envelope.v1",
      "intelligence_version": "1.0.0",
      "capability": "get_weekly_review",
      "status": "ok",
      "as_of": "2026-11-08",
      "period": {"start": "2026-11-02", "end": "2026-11-08", "days": 7, "weeks": 1,
                 "timezone": "GMT"},
      "subject": {"athlete": "self"},
      "units": {"load": "kg"},
      "facts": {"activity": {"value": {"completed_sessions": 2, "target_sessions": 3},
                             "basis": "derived", "method": "test", "unit": null,
                             "n": 2, "gate": "signal", "note": null}},
      "evidence": [],
      "coverage": {"sessions_considered": 2},
      "missing": [],
      "limitations": [],
      "quality_flags": [],
      "privacy": {"class": "health"},
      "provenance": {"builder_version": "context.v1"},
      "generated_at": "2026-11-16T07:02:11Z"
    }
    """

    private func envelope() throws -> IntelligenceEnvelope {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(IntelligenceEnvelope.self, from: Data(envelopeJSON.utf8))
    }

    func testToolCallRoundTripThenGroundedAnswer() async throws {
        let api = StubDeepSeekAPI(responses: [
            DeepSeekChatResult(
                content: nil,
                toolCalls: [
                    DeepSeekToolCall(
                        id: "call_1",
                        function: .init(name: "weekly_review", arguments: "{\"query\":\"\"}")
                    ),
                ]
            ),
            DeepSeekChatResult(content: "Two sessions this week.", toolCalls: []),
        ])
        let generator = DeepSeekChatGenerator(
            api: api, keyPresent: true, facts: StubFacts(envelope: try envelope())
        )
        let reply = try await generator.reply(to: "What changed?", history: [])
        XCTAssertEqual(reply.text, "Two sessions this week.")
        XCTAssertEqual(reply.sources, ["weekly review"])
        XCTAssertTrue(reply.unverifiedNumbers.isEmpty)
        XCTAssertEqual(api.calls.count, 2)
        XCTAssertTrue(
            api.calls[1].first(where: { $0.role == "tool" })?.content?.contains("activity") ?? false
        )
    }

    func testUngroundedAnswerRetriesThenShowsAWarning() async throws {
        let api = StubDeepSeekAPI(responses: [
            DeepSeekChatResult(content: "9 sessions this week.", toolCalls: []),
            DeepSeekChatResult(content: "9 sessions this week.", toolCalls: []),
        ])
        let generator = DeepSeekChatGenerator(
            api: api, keyPresent: true, facts: StubFacts(envelope: try envelope())
        )
        let reply = try await generator.reply(to: "What changed?", history: [])
        XCTAssertEqual(reply.unverifiedNumbers, ["9"])
        XCTAssertEqual(api.calls.count, 2)
        XCTAssertTrue(api.calls[1].contains { $0.role == "user" && ($0.content?.contains("Correction") ?? false) })
    }

    func testStructuredAnswerSeparatesSuggestions() async throws {
        let api = StubDeepSeekAPI(responses: [
            DeepSeekChatResult(
                content: "{\"answer\":\"Two sessions this week.\",\"suggestions\":[\"Try 105 kg next week.\"]}",
                toolCalls: []
            ),
        ])
        let generator = DeepSeekChatGenerator(
            api: api, keyPresent: true, facts: StubFacts(envelope: try envelope())
        )
        let reply = try await generator.reply(to: "What should I change?", history: [])
        XCTAssertEqual(reply.text, "Two sessions this week.")
        XCTAssertEqual(reply.suggestions, ["Try 105 kg next week."])
        XCTAssertTrue(reply.unverifiedNumbers.isEmpty)
    }

    func testPlanFactsAllFailIsFailure() async {
        let facts = StubFacts(envelope: try! envelope())
        facts.planErrors["prescription"] = APIError.unauthorized
        let result = await ChatPlanFacts.load(
            question: "what was prescribed yesterday", names: ["prescription"], facts: facts
        )
        XCTAssertEqual(result.status, .failure)
        XCTAssertEqual(result.failures["prescription"], .unauthorized)
        XCTAssertNil(result.context)
    }

    func testPlanFactsMixedIsPartial() async {
        let facts = StubFacts(envelope: try! envelope())
        facts.planErrors["adherence"] = APIError.transport("offline")
        let result = await ChatPlanFacts.load(
            question: "prescription and adherence", names: ["prescription", "adherence"],
            facts: facts
        )
        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.missing, ["adherence"])
        XCTAssertTrue(result.context?.contains("prescription facts") ?? false)
        XCTAssertTrue(result.context?.contains("Unavailable plan sections") ?? false)
    }

    func testPlanFailureStopsDeepSeekGeneration() async {
        let facts = StubFacts(envelope: try! envelope())
        facts.planErrors["prescription"] = APIError.unauthorized
        let api = StubDeepSeekAPI(responses: [])
        let generator = DeepSeekChatGenerator(
            api: api, keyPresent: true, facts: facts, includePlan: true
        )
        do {
            _ = try await generator.reply(to: "what was prescribed yesterday", history: [])
            XCTFail("expected an unavailable error")
        } catch let error as ChatError {
            guard case .unavailable = error else {
                return XCTFail("expected unavailable, got \(error)")
            }
        } catch {
            return XCTFail("expected unavailable, got \(error)")
        }
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testMissingKeyIsUnavailable() {
        let generator = DeepSeekChatGenerator(
            api: StubDeepSeekAPI(responses: []), keyPresent: false,
            facts: StubFacts(envelope: try! envelope())
        )
        XCTAssertFalse(generator.availability().isAvailable)
    }

    func testToolRoundCapStopsRunawayToolUse() async throws {
        let call = DeepSeekChatResult(
            content: nil,
            toolCalls: [
                DeepSeekToolCall(
                    id: "call", function: .init(name: "weekly_review", arguments: "{}")
                ),
            ]
        )
        let api = StubDeepSeekAPI(responses: Array(repeating: call, count: 5))
        let generator = DeepSeekChatGenerator(
            api: api, keyPresent: true, facts: StubFacts(envelope: try envelope())
        )
        do {
            _ = try await generator.reply(to: "What changed?", history: [])
            XCTFail("expected the round cap to stop")
        } catch let error as ChatError {
            guard case .failed(let message) = error else {
                return XCTFail("expected failed, got (error)")
            }
            XCTAssertTrue(message.contains("too many tool steps"))
            XCTAssertEqual(api.calls.count, 4)
        }
    }

    func testClientSendsBearerAndParsesToolCall() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
            XCTAssertTrue(request.url?.path.hasSuffix("/chat/completions") ?? false)
            let body = """
            {"choices":[{"message":{"content":null,"tool_calls":[
              {"id":"call_1","type":"function","function":{"name":"weekly_review","arguments":"{}"}}
            ]}}]}
            """
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }
        let client = DeepSeekClient(
            apiKey: "sk-test",
            baseURL: URL(string: "https://api.deepseek.com/")!,
            session: session
        )
        let result = try await client.complete(
            messages: [DeepSeekMessage(role: "user", content: "hello")],
            tools: DeepSeekTools.specs()
        )
        XCTAssertEqual(result.toolCalls.first?.function.name, "weekly_review")
    }

    func testClientMapsAuthAndRateLimitErrors() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = DeepSeekClient(
            apiKey: "sk-test",
            baseURL: URL(string: "https://api.deepseek.com/")!,
            session: session
        )
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
             Data("{}".utf8))
        }
        do {
            _ = try await client.complete(
                messages: [DeepSeekMessage(role: "user", content: "hi")], tools: []
            )
            XCTFail("expected invalidKey")
        } catch let error as DeepSeekError {
            XCTAssertEqual(error, .invalidKey)
        }

        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!,
             Data("{}".utf8))
        }
        do {
            _ = try await client.complete(
                messages: [DeepSeekMessage(role: "user", content: "hi")], tools: []
            )
            XCTFail("expected rateLimited")
        } catch let error as DeepSeekError {
            XCTAssertEqual(error, .rateLimited)
        }
    }

    func testMalformedResponseIsRejected() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("not json".utf8))
        }
        let client = DeepSeekClient(
            apiKey: "sk-test",
            baseURL: URL(string: "https://api.deepseek.com/")!,
            session: session
        )
        do {
            _ = try await client.complete(
                messages: [DeepSeekMessage(role: "user", content: "hi")], tools: []
            )
            XCTFail("expected badResponse")
        } catch let error as DeepSeekError {
            XCTAssertEqual(error, .badResponse)
        }
    }
}
