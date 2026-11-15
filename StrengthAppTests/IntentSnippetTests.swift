import SwiftUI
import XCTest

@testable import StrengthApp
import StrengthCore
import StrengthIntents

@MainActor
final class IntentSnippetTests: XCTestCase {
    private func envelope(_ raw: String) throws -> IntelligenceEnvelope {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(IntelligenceEnvelope.self, from: Data(raw.utf8))
    }

    private func render<V: View>(_ view: V) -> UIImage? {
        let renderer = ImageRenderer(content: view.frame(width: 340))
        renderer.scale = 2
        return renderer.uiImage
    }

    private let weekly = """
    {"schema_version":"intelligence.envelope.v1","capability":"get_weekly_review","status":"ok",
     "as_of":"2026-11-08",
     "period":{"start":"2026-11-02","end":"2026-11-08","days":7,"weeks":1,"timezone":"Europe/London"},
     "facts":{"activity":{"value":{"completed_sessions":2,"target_sessions":3,"working_sets":14},
                          "basis":"derived","method":"m","unit":null,"n":2,"gate":"signal","note":null},
              "progression":{"value":[{"display":"Trap Bar Deadlift","direction":"up",
                                       "change_kg":2.5,"n":6}],
                             "basis":"derived","method":"m","unit":null,"n":1,
                             "gate":"signal","note":null}},
     "observations":[],"coverage":{},"missing":[],"limitations":[]}
    """

    private let overview = """
    {"schema_version":"intelligence.envelope.v1","capability":"get_overview","status":"ok",
     "as_of":"2026-11-15",
     "period":{"start":"2026-10-19","end":"2026-11-15","days":28,"weeks":4,"timezone":"Europe/London"},
     "facts":{"attendance":{"value":{"completed":9,"target":12,"pct":75.0,
                                     "duration":{"n":8,"mean_min":54.4}},
                            "basis":"derived","method":"m","unit":null,"n":9,"gate":null,"note":null}},
     "observations":[],"coverage":{},"missing":[],"limitations":[]}
    """

    func testWeeklyReviewSnippetRenders() throws {
        let view = WeeklyReviewSnippetView(digest: WeeklyReviewDigest(envelope: try envelope(weekly)))
        let image = try XCTUnwrap(render(view))
        XCTAssertGreaterThan(image.size.width, 0)
    }

    func testOverviewSnippetRenders() throws {
        let view = OverviewSnippetView(digest: OverviewDigest(envelope: try envelope(overview)))
        XCTAssertNotNil(render(view))
    }

    func testAverageDurationSnippetRenders() throws {
        let digest = AverageDurationDigest(envelope: try envelope(overview), weeks: 4)
        XCTAssertNotNil(render(AverageDurationSnippetView(digest: digest)))
    }

    func testLastWorkoutSnippetRendersWithAndWithoutData() {
        let summary = LastWorkoutSummary(
            occurredOn: "2026-11-14", sessionType: "lower_a", durationMin: 52,
            workingSets: 14, mainLifts: ["Squat", "Bench"]
        )
        XCTAssertNotNil(render(LastWorkoutSnippetView(summary: summary)))
        XCTAssertNotNil(render(LastWorkoutSnippetView(summary: nil)))
    }

    func testProgressionSnippetRenders() {
        let view = ProgressionSnippetView(
            name: "Trap Bar Deadlift", direction: "up", changeKg: 5, sessions: 6
        )
        XCTAssertNotNil(render(view))
    }

    func testAppIntentsMetadataIsEmbeddedInTheApp() {
        let metadata = Bundle.main.bundleURL.appendingPathComponent("Metadata.appintents")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: metadata.path),
            "App Intents metadata is missing; Siri and Shortcuts would not see the intents"
        )
    }
}
