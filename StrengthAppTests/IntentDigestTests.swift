import XCTest

@testable import StrengthApp
import StrengthCore
import StrengthIntents

@MainActor
final class IntentDigestTests: XCTestCase {
    private func decode(_ raw: String) throws -> IntelligenceEnvelope {
        let decoder = JSONDecoder()
        // The app's client decodes the server's snake_case envelope the same way.
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(IntelligenceEnvelope.self, from: Data(raw.utf8))
    }

    private let weeklyReview = """
    {
      "schema_version": "intelligence.envelope.v1",
      "capability": "get_weekly_review",
      "status": "ok",
      "as_of": "2026-11-08",
      "period": {"start": "2026-11-02", "end": "2026-11-08", "days": 7, "weeks": 1,
                 "timezone": "Europe/London"},
      "facts": {
        "activity": {"value": {"completed_sessions": 2, "target_sessions": 3, "working_sets": 14},
                     "basis": "derived", "method": "strength_coach.features.attendance.summary",
                     "unit": null, "n": 2, "gate": "signal", "note": null},
        "progression": {"value": [{"exercise_id": "trap_bar_deadlift",
                                   "display": "Trap Bar Deadlift",
                                   "direction": "up", "change_kg": 2.5, "n": 6}],
                        "basis": "derived",
                        "method": "strength_coach.features.strength_trend.summarize",
                        "unit": null, "n": 1, "gate": "signal", "note": null}
      },
      "observations": [{"family": "rir", "text": "RIR was below band.", "gate": "signal",
                        "n": 2, "evidence_id": "ev:1", "limitations": ["Descriptive only."]}],
      "coverage": {}, "missing": [], "limitations": ["Attendance is target-based."]
    }
    """

    private let overview = """
    {
      "schema_version": "intelligence.envelope.v1",
      "capability": "get_overview",
      "status": "ok",
      "as_of": "2026-11-15",
      "period": {"start": "2026-10-19", "end": "2026-11-15", "days": 28, "weeks": 4,
                 "timezone": "Europe/London"},
      "facts": {
        "attendance": {"value": {"completed": 9, "target": 12, "pct": 75.0,
                                 "duration": {"n": 8, "mean_min": 54.4}},
                       "basis": "derived", "method": "m",
                       "unit": null, "n": 9, "gate": null, "note": null},
        "strength_trend": {"value": {"points": [{}, {}, {}], "latest": 1.02,
                                     "median_ratio": 1.0},
                           "basis": "derived", "method": "m",
                           "unit": "ratio", "n": 3, "gate": "signal", "note": null},
        "readiness_coverage": {"value": {"observed_days": 21, "window_days": 28},
                               "basis": "derived", "method": "m",
                               "unit": null, "n": 21, "gate": null, "note": null}
      },
      "observations": [],
      "coverage": {}, "missing": [], "limitations": []
    }
    """

    private let progression = """
    {
      "schema_version": "intelligence.envelope.v1",
      "capability": "get_exercise_progression",
      "status": "ok",
      "as_of": "2026-11-15",
      "period": {"start": "2026-08-23", "end": "2026-11-15", "days": 84, "weeks": 12,
                 "timezone": "Europe/London"},
      "facts": {
        "exercise": {"value": {"id": "trap_bar_deadlift", "display": "Trap Bar Deadlift"},
                     "basis": "observed", "method": "m",
                     "unit": null, "n": null, "gate": null, "note": null},
        "summary": {"value": {"direction": "up", "change_kg": 5.0, "n": 6},
                    "basis": "derived", "method": "m",
                    "unit": null, "n": 6, "gate": "signal", "note": null},
        "series": {"value": {"observations": [{}, {}, {}]},
                   "basis": "derived", "method": "m",
                   "unit": null, "n": 3, "gate": null, "note": null}
      },
      "observations": [],
      "coverage": {}, "missing": [], "limitations": []
    }
    """

    func testWeeklyReviewDigestSpeaksSessionsAndProgression() throws {
        let digest = WeeklyReviewDigest(envelope: try decode(weeklyReview))

        XCTAssertEqual(digest.completedSessions, 2)
        XCTAssertEqual(digest.targetSessions, 3)
        XCTAssertEqual(digest.workingSets, 14)
        XCTAssertEqual(digest.progression.first?.display, "Trap Bar Deadlift")
        XCTAssertTrue(digest.dialog.contains("2 of 3 sessions"))
        XCTAssertTrue(digest.dialog.contains("Trap Bar Deadlift"))
        XCTAssertTrue(digest.dialog.contains("2.5 kg"))
    }

    func testWeeklyReviewSpeaksDownwardProgressionWithoutADoubleSign() throws {
        let raw = weeklyReview
            .replacingOccurrences(of: "\"direction\": \"up\"", with: "\"direction\": \"down\"")
            .replacingOccurrences(of: "\"change_kg\": 2.5", with: "\"change_kg\": -2.5")
        let digest = WeeklyReviewDigest(envelope: try decode(raw))

        XCTAssertTrue(digest.dialog.contains("down 2.5 kg"))
        XCTAssertFalse(digest.dialog.contains(" up "))
        XCTAssertFalse(digest.dialog.contains("-2.5"))
    }

    func testWeeklyReviewSpeaksFlatProgressionAsUnchanged() throws {
        let raw = weeklyReview
            .replacingOccurrences(of: "\"direction\": \"up\"", with: "\"direction\": \"flat\"")
            .replacingOccurrences(of: "\"change_kg\": 2.5", with: "\"change_kg\": 0.0")
        let digest = WeeklyReviewDigest(envelope: try decode(raw))

        XCTAssertTrue(digest.dialog.contains("unchanged"))
        XCTAssertFalse(digest.dialog.contains(" up "))
        XCTAssertFalse(digest.dialog.contains(" down "))
    }

    func testOverviewDigestReportsNumbersWithoutComputing() throws {
        let digest = OverviewDigest(envelope: try decode(overview))

        XCTAssertEqual(digest.completedSessions, 9)
        XCTAssertEqual(digest.targetSessions, 12)
        XCTAssertEqual(digest.readinessDaysObserved, 21)
        XCTAssertEqual(digest.meanSessionMinutes, 54.4)
        XCTAssertTrue(digest.dialog.contains("9 of 12 sessions completed"))
        XCTAssertTrue(digest.dialog.contains("54.4 minutes"))
        XCTAssertTrue(digest.lines.contains { $0.label == "Adherence" && $0.value == "75%" })
    }

    func testOverviewDigestSaysWhenThereIsNoData() throws {
        let empty = """
        {"schema_version":"intelligence.envelope.v1","capability":"get_overview",
         "status":"no_data","as_of":"2026-11-15",
         "period":{"start":"2026-10-19","end":"2026-11-15","days":28,"weeks":4,
                   "timezone":"Europe/London"},
         "facts":{},"observations":[],"coverage":{},"missing":[],"limitations":[]}
        """
        let digest = OverviewDigest(envelope: try decode(empty))

        XCTAssertNil(digest.completedSessions)
        XCTAssertTrue(digest.dialog.contains("not enough training data"))
    }

    func testProgressionDialogUsesTheEntityNameWhenTheEnvelopeOmitsIt() throws {
        let digest = ProgressionDigest(envelope: try decode(progression))

        XCTAssertEqual(digest.dialog(fallbackName: "Fallback"), "Trap Bar Deadlift: strength up 5.0 kg over 6 sessions.")

        let bare = """
        {"schema_version":"intelligence.envelope.v1","capability":"get_exercise_progression",
         "status":"no_data","as_of":"2026-11-15",
         "period":{"start":"2026-08-23","end":"2026-11-15","days":84,"weeks":12,
                   "timezone":"Europe/London"},
         "facts":{},"observations":[],"coverage":{},"missing":[],"limitations":[]}
        """
        let empty = ProgressionDigest(envelope: try decode(bare))
        XCTAssertEqual(empty.dialog(fallbackName: "Fallback"),
                       "Fallback: not enough comparable sessions for a trend yet.")
    }

    func testAverageDurationDigestNamesTheWindowAndTheSample() throws {
        let digest = AverageDurationDigest(envelope: try decode(overview), weeks: 4)

        XCTAssertEqual(digest.sessionCount, 8)
        XCTAssertEqual(digest.meanMinutes, 54.4)
        XCTAssertTrue(digest.dialog.contains("over the last 4 weeks"))
        XCTAssertTrue(digest.dialog.contains("54.4 minutes"))
        XCTAssertTrue(digest.dialog.contains("based on 8 sessions"))
        XCTAssertEqual(digest.lines.first?.label, "Average")
    }

    func testAverageDurationDigestSaysWhenNothingWasRecorded() throws {
        let empty = """
        {"schema_version":"intelligence.envelope.v1","capability":"get_overview",
         "status":"no_data","as_of":"2026-11-15",
         "period":{"start":"2026-10-19","end":"2026-11-15","days":28,"weeks":4,
                   "timezone":"Europe/London"},
         "facts":{},"observations":[],"coverage":{},"missing":[],"limitations":[]}
        """
        let digest = AverageDurationDigest(envelope: try decode(empty), weeks: 8)

        XCTAssertNil(digest.meanMinutes)
        XCTAssertEqual(digest.dialog, "No session durations were recorded over the last 8 weeks.")
    }

    func testLastWorkoutDialogStatesDurationAndSets() {
        let summary = LastWorkoutSummary(
            occurredOn: "2026-11-14",
            sessionType: "lower_a",
            durationMin: 52,
            workingSets: 14,
            mainLifts: ["Squat"]
        )

        XCTAssertEqual(
            summary.dialog,
            "Your last workout (Lower A) was 52 minutes long on 2026-11-14. It had 14 working sets."
        )
    }

    func testExerciseQueryFiltersByIdentifierThroughTheRegisteredProvider() async throws {
        let provider = StubIntentProvider()
        provider.catalogue = [
            ExerciseEntity(id: "trap_bar_deadlift", name: "Trap Bar Deadlift"),
            ExerciseEntity(id: "squat", name: "Squat"),
        ]
        IntentServices.register(provider)

        let entities = try await ExerciseEntityQuery().entities(for: ["squat"])

        XCTAssertEqual(entities.map(\.id), ["squat"])
        XCTAssertEqual(provider.catalogueCalls, 1)
        // Indexed for Spotlight: the default attribute set carries the display name as its title.
        let attributes = try XCTUnwrap(entities.first?.attributeSet)
        XCTAssertEqual(attributes.title ?? attributes.displayName, "Squat")
    }
}

/// Minimal read-only provider used to prove the registry and the entity query without a server.
final class StubIntentProvider: IntentDataProviding {
    var catalogue: [ExerciseEntity] = []
    var catalogueCalls = 0

    func overview(windowWeeks: Int) async throws -> IntelligenceEnvelope {
        throw IntentServiceError.notPaired
    }

    func weeklyReview() async throws -> IntelligenceEnvelope {
        throw IntentServiceError.notPaired
    }

    func progression(exerciseID: String) async throws -> IntelligenceEnvelope {
        throw IntentServiceError.notPaired
    }

    func exerciseCatalogue() async throws -> [ExerciseEntity] {
        catalogueCalls += 1
        return catalogue
    }

    func lastWorkout() async throws -> LastWorkoutSummary? {
        nil
    }
}
