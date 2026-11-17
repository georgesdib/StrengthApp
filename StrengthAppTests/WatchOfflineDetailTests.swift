import XCTest

import StrengthCore

/// The watch used to say "Connect to home Wi-Fi" for every transport failure, which hid a stale
/// home-server address and a refused scheme behind a connectivity instruction. The detail now
/// names the host and the reason.
final class WatchOfflineDetailTests: XCTestCase {
    func testDetailNamesTheHostAndTheReason() {
        let detail = WatchOfflineDetail.make(
            baseURL: "http://home.local:8000",
            reason: "iOS refuses plain http:// to this address."
        )
        XCTAssertTrue(detail.hasPrefix("home.local — "), detail)
        XCTAssertTrue(detail.contains("refuses"), detail)
    }

    func testDetailFallsBackToTheHostAlone() {
        XCTAssertEqual(
            WatchOfflineDetail.make(baseURL: "https://odroid.example:8000", reason: nil),
            "odroid.example"
        )
    }

    func testDetailKeepsTheRawAddressWhenItHasNoHost() {
        XCTAssertEqual(WatchOfflineDetail.make(baseURL: "not a url", reason: nil), "not a url")
    }
}
