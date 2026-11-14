import XCTest

@testable import StrengthApp
import StrengthCore

@MainActor
final class RedirectPolicyTests: XCTestCase {
    func testSameOriginAllowsEquivalentDefaultPortsAndPaths() {
        XCTAssertTrue(
            RedirectPolicy.allowsRedirect(
                from: URL(string: "http://127.0.0.1:8000/api/ios/v1/bootstrap"),
                to: URL(string: "http://127.0.0.1:8000/api/ios/v1/today")
            )
        )
        XCTAssertTrue(
            RedirectPolicy.allowsRedirect(
                from: URL(string: "http://gym.local:80/start"),
                to: URL(string: "http://gym.local/next")
            )
        )
        XCTAssertTrue(
            RedirectPolicy.allowsRedirect(
                from: URL(string: "https://gym.local:443/start"),
                to: URL(string: "https://gym.local/next")
            )
        )
        XCTAssertTrue(
            RedirectPolicy.allowsRedirect(
                from: URL(string: "https://GYM.Local/start"),
                to: URL(string: "https://gym.local/next")
            )
        )
    }

    func testDifferentPortIsDenied() {
        XCTAssertFalse(
            RedirectPolicy.allowsRedirect(
                from: URL(string: "http://127.0.0.1:8000/api/ios/v1/bootstrap"),
                to: URL(string: "http://127.0.0.1:9000/api/ios/v1/bootstrap")
            )
        )
        XCTAssertFalse(
            RedirectPolicy.allowsRedirect(
                from: URL(string: "https://gym.local:443/start"),
                to: URL(string: "https://gym.local:8443/start")
            )
        )
        XCTAssertFalse(
            RedirectPolicy.allowsRedirect(
                from: URL(string: "http://gym.local/start"),
                to: URL(string: "http://gym.local:8080/start")
            )
        )
    }

    func testSchemeChangeIsDenied() {
        XCTAssertFalse(
            RedirectPolicy.allowsRedirect(
                from: URL(string: "http://gym.local:8000/start"),
                to: URL(string: "https://gym.local:8000/start")
            )
        )
        XCTAssertFalse(
            RedirectPolicy.allowsRedirect(
                from: URL(string: "https://gym.local/start"),
                to: URL(string: "http://gym.local/start")
            )
        )
    }

    func testDifferentHostAndSubdomainAreDenied() {
        XCTAssertFalse(
            RedirectPolicy.allowsRedirect(
                from: URL(string: "http://127.0.0.1:8000/start"),
                to: URL(string: "http://127.0.0.2:8000/start")
            )
        )
        XCTAssertFalse(
            RedirectPolicy.allowsRedirect(
                from: URL(string: "https://gym.local/start"),
                to: URL(string: "https://api.gym.local/start")
            )
        )
    }

    func testUserInfoAndNonHTTPTargetsAreDenied() {
        XCTAssertFalse(
            RedirectPolicy.allowsRedirect(
                from: URL(string: "http://gym.local:8000/start"),
                to: URL(string: "http://user:pass@gym.local:8000/start")
            )
        )
        XCTAssertFalse(
            RedirectPolicy.allowsRedirect(
                from: URL(string: "http://gym.local:8000/start"),
                to: URL(string: "ftp://gym.local:8000/start")
            )
        )
        XCTAssertFalse(
            RedirectPolicy.allowsRedirect(
                from: URL(string: "http://gym.local:8000/start"),
                to: URL(string: "file:///tmp/start")
            )
        )
    }

    func testMissingURLsAreDenied() {
        XCTAssertFalse(RedirectPolicy.allowsRedirect(from: nil, to: URL(string: "http://gym.local/start")))
        XCTAssertFalse(RedirectPolicy.allowsRedirect(from: URL(string: "http://gym.local/start"), to: nil))
        XCTAssertFalse(RedirectPolicy.allowsRedirect(from: nil, to: nil))
    }

    func testDelegateRejectsCrossOriginAndKeepsTheOriginalCredential() throws {
        let session = URLSession(configuration: .ephemeral)
        let originalURL = try XCTUnwrap(URL(string: "http://127.0.0.1:8000/api/ios/v1/bootstrap"))
        var original = URLRequest(url: originalURL)
        original.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        let task = session.dataTask(with: original)
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: originalURL,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": "http://127.0.0.1:9000/"]
            )
        )
        let redirectGuard = SameHostRedirectGuard()

        var crossOrigin: URLRequest?
        redirectGuard.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:9000/"))),
            completionHandler: { crossOrigin = $0 }
        )
        XCTAssertNil(crossOrigin, "a cross-port redirect must not be followed")

        var sameOrigin: URLRequest?
        redirectGuard.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:8000/api/ios/v1/today"))),
            completionHandler: { sameOrigin = $0 }
        )
        XCTAssertEqual(
            sameOrigin?.url?.absoluteString,
            "http://127.0.0.1:8000/api/ios/v1/today"
        )

        // The credential stays on the original request. A rejected redirect has no target
        // request, so the bearer token cannot be forwarded to the other origin.
        XCTAssertEqual(
            task.originalRequest?.value(forHTTPHeaderField: "Authorization"),
            "Bearer secret-token"
        )
    }
}
