import XCTest

@testable import StrengthApp
import StrengthCore

/// The app ships only `NSAllowsLocalNetworking`, so cleartext HTTP works to private, loopback
/// and link-local addresses, `.local` names and single-word names, and nothing else. The
/// boundary below was measured on the iOS 27.2 runtime with a probe request: private RFC1918
/// addresses reach the network layer, while a public address and a Tailscale CGNAT address are
/// refused with -1022 before a packet is sent.
final class ServerAddressPolicyTests: XCTestCase {
    func testPublicHostNameOverHTTPIsBlocked() {
        XCTAssertTrue(ServerAddressPolicy.cleartextIsBlocked("http://odroid.tailnet.ts.net:8000"))
        XCTAssertTrue(ServerAddressPolicy.cleartextIsBlocked("http://away.example.com:8000"))
        XCTAssertTrue(ServerAddressPolicy.cleartextIsBlocked("http://example.org"))
    }

    func testTheSameHostOverHTTPSIsAllowed() {
        XCTAssertFalse(ServerAddressPolicy.cleartextIsBlocked("https://odroid.tailnet.ts.net:8000"))
    }

    func testPrivateAddressesAreAllowed() {
        XCTAssertFalse(ServerAddressPolicy.cleartextIsBlocked("http://192.168.1.10:8000"))
        XCTAssertFalse(ServerAddressPolicy.cleartextIsBlocked("http://10.0.0.44:8000"))
        XCTAssertFalse(ServerAddressPolicy.cleartextIsBlocked("http://172.16.5.4:8000"))
        XCTAssertFalse(ServerAddressPolicy.cleartextIsBlocked("http://169.254.1.1:8000"))
        XCTAssertFalse(ServerAddressPolicy.cleartextIsBlocked("http://127.0.0.1:8000"))
        XCTAssertFalse(ServerAddressPolicy.cleartextIsBlocked("http://[fd7a:115c:a1e0::1]:8000"))
        XCTAssertFalse(ServerAddressPolicy.cleartextIsBlocked("http://[::1]:8000"))
    }

    /// A Tailscale address is CGNAT, not private, so it is refused like a public one. This is the
    /// case that produced the original failure and is the reason the rule is not "any IP address".
    func testCGNATAddressesAreBlocked() {
        XCTAssertTrue(ServerAddressPolicy.cleartextIsBlocked("http://100.64.0.1:8000"))
        XCTAssertTrue(ServerAddressPolicy.cleartextIsBlocked("http://100.101.102.103:8000"))
        XCTAssertTrue(ServerAddressPolicy.cleartextIsBlocked("http://100.127.255.254:8000"))
    }

    func testPublicIPAddressesAreBlocked() {
        XCTAssertTrue(ServerAddressPolicy.cleartextIsBlocked("http://203.0.113.7:8000"))
        XCTAssertTrue(ServerAddressPolicy.cleartextIsBlocked("http://[2001:db8::1]:8000"))
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
