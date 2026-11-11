import XCTest
@testable import StrengthApp
import StrengthCore

final class ExerciseCatalogueCacheTests: XCTestCase {
    func testCatalogueCacheRoundTripsAndRejectsAnotherServer() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalogue-\(UUID().uuidString).json")
        let cache = ExerciseCatalogueCache(fileURL: url)
        let exercises = [
            ExerciseOption(id: "competition_squat", display: "Competition Squat", pattern: "squat"),
            ExerciseOption(id: "bench_press", display: "Bench Press", pattern: nil),
        ]
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try cache.save(
            serverURL: "http://home.local:8000",
            exercises: exercises,
            fetchedAt: fetchedAt
        )

        let loaded = try XCTUnwrap(cache.load(serverURL: "http://home.local:8000"))
        XCTAssertEqual(loaded.exercises, exercises)
        XCTAssertEqual(loaded.fetchedAt.timeIntervalSince1970, fetchedAt.timeIntervalSince1970)
        XCTAssertNil(cache.load(serverURL: "http://away.local:8000"))

        cache.clear()
        XCTAssertNil(cache.load(serverURL: "http://home.local:8000"))
    }

    func testCorruptCacheIsIgnored() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalogue-\(UUID().uuidString).json")
        try Data("not json".utf8).write(to: url)
        let cache = ExerciseCatalogueCache(fileURL: url)
        XCTAssertNil(cache.load(serverURL: "http://home.local:8000"))
    }
}
