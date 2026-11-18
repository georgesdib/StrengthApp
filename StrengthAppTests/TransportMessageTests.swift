import XCTest

@testable import StrengthApp
import StrengthCore

/// -1022 is a client policy refusal, not a server fault. The system sentence names the rule and
/// not the remedy, so the client supplies its own text.
@MainActor
final class TransportMessageTests: XCTestCase {
    func testATSFailureNamesHTTPSInsteadOfEchoingTheSystemText() async {
        let transport = StubTransport { _ in
            throw URLError(.appTransportSecurityRequiresSecureConnection)
        }
        let client = IOSAPIClient(transport: transport)
        let session = IOSSession(
            baseURL: URL(string: "http://odroid.tailnet.ts.net:8000")!,
            token: "token-abc"
        )
        do {
            _ = try await client.bootstrap(session: session)
            XCTFail("expected the cleartext request to fail")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("https://"), "unhelpful message: \(message)")
            XCTAssertFalse(
                message.localizedCaseInsensitiveContains("App Transport Security"),
                "the system sentence was passed through: \(message)"
            )
        }
    }
}
