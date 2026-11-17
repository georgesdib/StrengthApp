import XCTest
@testable import StrengthApp
import StrengthCore

final class ReadinessLabelTests: XCTestCase {
    func testTheReviewShowsTheScoreAsAPercentage() throws {
        let score = try JSONDecoder().decode(
            ReadinessScore.self,
            from: Data(#"{"status":"ready","score":0.56}"#.utf8)
        )
        XCTAssertEqual(PrescriptionPreviewView.readinessLabel(score), "56% · Ready")
    }
}
