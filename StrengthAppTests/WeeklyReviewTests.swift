import XCTest
import StrengthCore

final class WeeklyReviewTests: XCTestCase {
    private let fixture = """
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
      "facts": {
        "activity": {"value": {"completed_sessions": 2, "target_sessions": 3,
                                "working_sets": 3},
                      "basis": "derived",
                      "method": "strength_coach.features.attendance.summary",
                      "unit": null, "n": 2, "gate": "signal", "note": null,
                      "evidence_ids": [], "unknown_fact_key": true},
        "progression": {"value": [{"exercise_id": "trap_bar_deadlift",
                                   "display": "Trap Bar Deadlift",
                                   "direction": "up", "change_kg": 1.2, "n": 6}],
                        "basis": "derived",
                        "method": "strength_coach.features.strength_trend.summarize",
                        "unit": null, "n": 1, "gate": "signal", "note": null}
      },
      "evidence": [],
      "observations": [{"family": "rir", "text": "RIR was below band.", "gate": "signal",
                        "n": 2, "evidence_id": "ev:1", "limitations": ["Descriptive only."]}],
      "coverage": {"sessions_considered": 2, "planned_sessions": "not_tracked"},
      "missing": ["no observation passed its evidence gate"],
      "limitations": ["Attendance is target-based."],
      "quality_flags": ["incomplete"],
      "privacy": {"class": "health"},
      "provenance": {"builder_version": "context.v1"},
      "generated_at": "2026-11-16T07:02:11Z",
      "unknown_top_level": {"ignored": true}
    }
    """

    private func decode(_ raw: String) throws -> IntelligenceEnvelope {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(IntelligenceEnvelope.self, from: Data(raw.utf8))
    }

    func testEnvelopeDecodesAndIgnoresUnknownFields() throws {
        let envelope = try decode(fixture)
        XCTAssertEqual(envelope.capability, "get_weekly_review")
        XCTAssertEqual(envelope.status, "ok")
        XCTAssertEqual(envelope.period.start, "2026-11-02")
        XCTAssertEqual(envelope.period.end, "2026-11-08")
        XCTAssertEqual(envelope.facts["activity"]?.value.objectValue?["completed_sessions"]?.intValue, 2)
        XCTAssertEqual(envelope.facts["progression"]?.value.arrayValue?.count, 1)
        XCTAssertEqual(envelope.observations?.first?.family, "rir")
        XCTAssertEqual(envelope.qualityFlags, ["incomplete"])
        XCTAssertEqual(envelope.coverage["sessions_considered"]?.intValue, 2)
    }

    func testMissingRequiredFieldFailsDecoding() throws {
        var broken = fixture.replacingOccurrences(
            of: "\"capability\": \"get_weekly_review\",", with: ""
        )
        XCTAssertThrowsError(try decode(broken))
        broken = fixture.replacingOccurrences(of: "\"facts\": {", with: "\"facts_removed\": {")
        XCTAssertThrowsError(try decode(broken))
    }

    func testNavigationShiftsWholeWeeksOnly() {
        XCTAssertEqual(WeeklyReviewDates.shift("2026-11-08", byDays: -7), "2026-11-01")
        XCTAssertEqual(WeeklyReviewDates.shift("2026-11-02", byDays: 7), "2026-11-09")
        XCTAssertNil(WeeklyReviewDates.shift("not-a-date", byDays: -7))
    }

    func testWeekLabelIsNatural() {
        XCTAssertEqual(
            WeeklyReviewDates.weekLabel(start: "2026-11-02", end: "2026-11-08"),
            "2–8 November 2026"
        )
        XCTAssertEqual(
            WeeklyReviewDates.weekLabel(start: "2026-09-28", end: "2026-10-04"),
            "28 September – 4 October 2026"
        )
        XCTAssertNil(WeeklyReviewDates.weekLabel(start: "bad", end: "2026-10-04"))
    }

    @MainActor
    func testViewModelLoadsAndStepsBack() async throws {
        let envelope = try decode(fixture)
        var requested: [String?] = []
        let model = WeeklyReviewViewModel { weekEnd in
            requested.append(weekEnd)
            return envelope
        }
        await model.load()
        XCTAssertEqual(model.envelope?.capability, "get_weekly_review")
        XCTAssertNil(model.errorMessage)
        await model.step(byWeeks: -1)
        XCTAssertEqual(requested.count, 2)
        XCTAssertEqual(requested.last ?? nil, "2026-11-01")
    }
}


extension WeeklyReviewTests {
    func testBootstrapCapabilityIsAdditive() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let old = """
        {"api_version":"1","server_date":"2026-11-15","server_time":"2026-11-15T09:00:00Z",
         "utc_offset_minutes":0,"server_timezone":"GMT",
         "capabilities":{"readiness":true,"prescription":true,"workout_write":true,
                         "healthkit":false,"offline":false}}
        """
        let decoded = try decoder.decode(BootstrapResponse.self, from: Data(old.utf8))
        XCTAssertNil(decoded.capabilities.intelligenceRead)

        let new = old.replacingOccurrences(
            of: "\"offline\":false", with: "\"offline\":false,\"intelligence_read\":true"
        )
        let withRoute = try decoder.decode(BootstrapResponse.self, from: Data(new.utf8))
        XCTAssertEqual(withRoute.capabilities.intelligenceRead, true)
    }

    @MainActor
    func testViewModelSurfacesFailuresWithoutNegativeFraming() async {
        let failures: [APIError] = [
            .http(status: 404, message: "not found", fields: [:]),
            .http(status: 503, message: "capabilities disabled", fields: [:]),
            .transport("The request timed out."),
            .unauthorized,
            .decoding,
        ]
        for failure in failures {
            let model = WeeklyReviewViewModel { _ in throw failure }
            await model.load()
            XCTAssertNil(model.envelope)
            let message = model.errorMessage ?? ""
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(message.lowercased().contains("missed"))
            XCTAssertFalse(message.lowercased().contains("injury"))
        }
    }
}
