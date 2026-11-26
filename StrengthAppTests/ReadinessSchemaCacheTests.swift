import XCTest

@testable import StrengthApp
import StrengthCore

final class ReadinessSchemaCacheTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("readiness-schema-\(UUID().uuidString).json")
    }

    func testCacheRoundTripsTheLastSchemaPerServer() throws {
        let url = temporaryURL()
        let cache = ReadinessSchemaCache(fileURL: url)
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try cache.save(
            serverURL: "http://home.local:8000",
            schema: .fallback,
            fetchedAt: fetchedAt
        )

        let loaded = try XCTUnwrap(cache.load(serverURL: "http://home.local:8000"))
        XCTAssertEqual(loaded.schema, .fallback)
        XCTAssertEqual(loaded.fetchedAt.timeIntervalSince1970, fetchedAt.timeIntervalSince1970)
        XCTAssertNil(cache.load(serverURL: "http://away.local:8000"))

        cache.clear()
        XCTAssertNil(cache.load(serverURL: "http://home.local:8000"))
    }

    func testMissingOrCorruptCacheFallsBackToTheFixedFields() throws {

        let url = temporaryURL()
        let cache = ReadinessSchemaCache(fileURL: url)
        XCTAssertNil(cache.load(serverURL: "http://home.local:8000"))

        try Data("not json".utf8).write(to: url)
        XCTAssertNil(cache.load(serverURL: "http://home.local:8000"))
        XCTAssertEqual(ReadinessSchema.fallback.enabledMetrics.count, 7)
    }

    func testCacheStoresAServerSchemaAfterItIsFetched() throws {
        let url = temporaryURL()
        let cache = ReadinessSchemaCache(fileURL: url)
        let schema = ReadinessSchema(
            registryId: 12,
            effectiveFrom: "2026-11-24",
            schemaVersion: 1,
            minCoreFields: 2,
            requireAnyOf: ["mood"],
            wearableWeight: 0.2,
            metrics: ReadinessSchema.fallback.metrics
        )
        try cache.save(serverURL: "http://home.local:8000", schema: schema)
        let loaded = try XCTUnwrap(cache.load(serverURL: "http://home.local:8000"))
        XCTAssertEqual(loaded.schema.registryId, 12)
        XCTAssertEqual(loaded.schema.minCoreFields, 2)
        XCTAssertEqual(loaded.schema.requireAnyOf, ["mood"])
    }
}
