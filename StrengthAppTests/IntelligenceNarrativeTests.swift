import XCTest
import StrengthCore

final class IntelligenceNarrativeTests: XCTestCase {
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
      "facts": {
        "activity": {"value": {"completed_sessions": 2, "target_sessions": 3},
                     "basis": "derived",
                     "method": "strength_coach.features.attendance.summary",
                     "unit": null, "n": 2, "gate": "signal", "note": null},
        "readiness": {"value": {"observed_days": 4, "direction": "flat"},
                      "basis": "derived",
                      "method": "strength_coach.features.readiness_score.compute",
                      "unit": null, "n": 4, "gate": "signal", "note": null}
      },
      "evidence": [{"id": "ev:1", "source": "test"}],
      "observations": [{"family": "rir", "text": "RIR was below band.", "gate": "signal",
                        "n": 2, "evidence_id": "ev:1", "limitations": ["Descriptive only."]}],
      "coverage": {"sessions_considered": 2},
      "missing": [],
      "limitations": ["Attendance is target-based."],
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

    func testProjectionContainsFactsUnitsAndGatesButNotEvidence() throws {
        let context = NarrativeContext.weeklyReview(try envelope(), detail: .standard)
        XCTAssertTrue(context.facts.contains("activity"))
        XCTAssertTrue(context.facts.contains("completed_sessions=2"))
        XCTAssertTrue(context.facts.contains("gate: signal"))
        XCTAssertTrue(context.facts.contains("RIR was below band."))
        XCTAssertFalse(context.facts.contains("ev:1"))
        XCTAssertFalse(context.facts.contains("provenance"))
    }

    func testValidatorAcceptsGroundedTextWithinLimits() throws {
        let context = NarrativeContext.weeklyReview(try envelope(), detail: .standard)
        let narrative = GeneratedNarrative(
            headline: "Two of three sessions",
            observations: ["Two sessions completed against a target of 3."],
            limitation: "Attendance is target-based."
        )
        XCTAssertNoThrow(try NarrativeValidator.validate(narrative, context: context))
    }

    func testValidatorRejectsInventedNumbers() throws {
        let context = NarrativeContext.weeklyReview(try envelope(), detail: .standard)
        let narrative = GeneratedNarrative(
            headline: "Five of three sessions",
            observations: ["Five sessions completed."],
            limitation: "Attendance is target-based."
        )
        XCTAssertThrowsError(try NarrativeValidator.validate(narrative, context: context)) { error in
            guard case NarrativeError.notGrounded = error else {
                return XCTFail("expected notGrounded, got \(error)")
            }
        }
    }

    func testValidatorRejectsOverlongOutput() throws {
        let context = NarrativeContext.weeklyReview(try envelope(), detail: .concise)
        let narrative = GeneratedNarrative(
            headline: String(repeating: "a", count: 200),
            observations: ["Two sessions completed."],
            limitation: "Attendance is target-based."
        )
        XCTAssertThrowsError(try NarrativeValidator.validate(narrative, context: context)) { error in
            guard case NarrativeError.tooLong = error else {
                return XCTFail("expected tooLong, got \(error)")
            }
        }
    }

    func testDetailPresetsScaleTheLayout() {
        XCTAssertLessThan(NarrativeDetail.concise.observationCount,
                          NarrativeDetail.detailed.observationCount)
        XCTAssertLessThan(NarrativeDetail.standard.observationLimit,
                          NarrativeDetail.detailed.observationLimit)
        XCTAssertEqual(NarrativeDetail.standard.observationCount, 3)
    }

    func testOverviewProjectionUsesTheSameFacts() throws {
        let context = NarrativeContext.overview(try envelope(), detail: .standard)
        XCTAssertEqual(context.kind, .overview)
        XCTAssertTrue(context.facts.contains("completed_sessions=2"))
    }
}
