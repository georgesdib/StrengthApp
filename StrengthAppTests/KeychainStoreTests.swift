import XCTest

@testable import StrengthApp
import StrengthCore

@MainActor
final class KeychainStoreTests: XCTestCase {
    private func makeStore() -> KeychainTokenStore {
        KeychainTokenStore(
            service: "com.georgesdibpersonalteam.StrengthApp.tests.\(UUID().uuidString)",
            account: "api-token"
        )
    }

    func testSaveLoadAndDelete() throws {
        let store = makeStore()
        defer { store.delete() }

        XCTAssertNil(store.load())
        try store.save("first-token")
        XCTAssertEqual(store.load(), "first-token")
        store.delete()
        XCTAssertNil(store.load())
    }

    func testSaveReplacesTheExistingToken() throws {
        let store = makeStore()
        defer { store.delete() }

        try store.save("first-token")
        try store.save("second-token")
        XCTAssertEqual(store.load(), "second-token")
    }

    func testDifferentAccountsAreIsolated() throws {
        let service = "com.georgesdibpersonalteam.StrengthApp.tests.\(UUID().uuidString)"
        let first = KeychainTokenStore(service: service, account: "first")
        let second = KeychainTokenStore(service: service, account: "second")
        defer {
            first.delete()
            second.delete()
        }

        try first.save("one")
        try second.save("two")
        XCTAssertEqual(first.load(), "one")
        XCTAssertEqual(second.load(), "two")
        second.delete()
        XCTAssertEqual(first.load(), "one")
        XCTAssertNil(second.load())
    }
}
