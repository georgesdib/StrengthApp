import XCTest

@testable import StrengthApp
import StrengthCore

/// The app ships only `NSAllowsLocalNetworking`, so cleartext HTTP works to local resources and
/// nothing else. These cases pin the boundary: a public host name over http:// is refused by iOS
/// before a request is sent, and the app now says so while the address is being edited.
final class ServerAddressPolicyTests: XCTestCase {
    func testPublicHostNameOverHTTPIsBlocked() {
        XCTAssertTrue(ServerAddressPolicy.cleartextIsBlocked("http://odroid.tailnet.ts.net:8000"))
        XCTAssertTrue(ServerAddressPolicy.cleartextIsBlocked("http://away.example.com:8000"))
        XCTAssertTrue(ServerAddressPolicy.cleartextIsBlocked("http://example.org"))
    }

    func testTheSameHostOverHTTPSIsAllowed() {
        XCTAssertFalse(ServerAddressPolicy.cleartextIsBlocked("https://odroid.tailnet.ts.net:8000"))
    }

    func testIPLiteralsAreAllowed() {
        XCTAssertFalse(ServerAddressPolicy.cleartextIsBlocked("http://192.168.1.10:8000"))
        XCTAssertFalse(ServerAddressPolicy.cleartextIsBlocked("http://10.0.0.44:8000"))
        // A Tailscale address is an IP literal, so it is a local resource for ATS.
        XCTAssertFalse(ServerAddressPolicy.cleartextIsBlocked("http://100.101.102.103:8000"))
        XCTAssertFalse(ServerAddressPolicy.cleartextIsBlocked("http://[fd7a:115c:a1e0::1]:8000"))
    }

    func testDotLocalAndUnqualifiedNamesAreAllowed() {
        XCTAssertFalse(ServerAddressPolicy.cleartextIsBlocked("http://odroid.local:8000"))
        XCTAssertFalse(ServerAddressPolicy.cleartextIsBlocked("http://odroid:8000"))
        XCTAssertFalse(ServerAddressPolicy.cleartextIsBlocked("http://localhost:8000"))
    }

    func testEmptyOrUnparseableInputIsNotAWarning() {
        XCTAssertFalse(ServerAddressPolicy.cleartextIsBlocked(""))
        XCTAssertFalse(ServerAddressPolicy.cleartextIsBlocked("   "))
        XCTAssertFalse(ServerAddressPolicy.cleartextIsBlocked("odroid.tailnet.ts.net:8000"))
    }
}
