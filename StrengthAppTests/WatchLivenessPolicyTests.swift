import XCTest

@testable import StrengthApp
import StrengthCore

/// Phase 6.3: liveness is only claimed after the HealthKit anchor actually started.
final class WatchLivenessPolicyTests: XCTestCase {
    func testIdleSessionClaimsNothing() {
        let policy = WatchLivenessPolicy()
        XCTAssertFalse(policy.isRunning)
        XCTAssertFalse(policy.isForegroundOnly)
        XCTAssertNil(policy.banner)
        XCTAssertNil(policy.detail)
    }

    func testRunningSessionShowsNoWarning() {
        var policy = WatchLivenessPolicy()
        policy.started()
        XCTAssertTrue(policy.isRunning)
        XCTAssertNil(policy.banner)
    }

    func testMissingAuthorizationIsForegroundOnlyWithTheContractSentence() {
        var policy = WatchLivenessPolicy()
        policy.authorizationUnavailable()
        XCTAssertFalse(policy.isRunning)
        XCTAssertTrue(policy.isForegroundOnly)
        XCTAssertEqual(policy.banner, WatchLivenessPolicy.bannerText)
        XCTAssertNotNil(policy.detail)
    }

    func testFailedStartKeepsTheReasonAndCanRecoverOnTheNextAttempt() {
        var policy = WatchLivenessPolicy()
        policy.failed("HealthKit refused")
        XCTAssertTrue(policy.isForegroundOnly)
        XCTAssertEqual(policy.detail, "HealthKit refused")

        policy.started()
        XCTAssertTrue(policy.isRunning)
        XCTAssertNil(policy.banner, "a successful retry clears the warning")
    }

    func testEndingTheSessionResetsTheClaim() {
        var policy = WatchLivenessPolicy()
        policy.started()
        policy.reset()
        XCTAssertFalse(policy.isRunning)
        XCTAssertFalse(policy.isForegroundOnly)
    }
}
