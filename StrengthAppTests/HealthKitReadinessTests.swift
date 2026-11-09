import XCTest

@testable import StrengthApp
import StrengthCore

@MainActor
final class HealthKitReadinessTests: XCTestCase {
    private func observation(
        _ field: HealthKitReadinessField,
        _ value: Double,
        id: String,
        at: Date,
        sourceClass: HealthKitSourceClass
    ) -> HealthKitReadinessObservation {
        HealthKitReadinessObservation(
            field: field,
            value: value,
            sampleID: id,
            sampleAt: at,
            sourceName: sourceClass == .appleWatch ? "Apple Watch" : "Other",
            sourceBundleID: "com.example.source",
            sourceClass: sourceClass,
            sourceModel: sourceClass == .appleWatch ? "Watch6,18" : "Other",
            sourceManufacturer: sourceClass == .appleWatch ? "Apple Inc." : "Other"
        )
    }

    private func serverDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func testReadinessPayloadDecodesHealthKitProvenance() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(ReadinessPayload.self, from: Data(#"""
        {
          "on_date": "2026-11-08",
          "hrv_ms": 55.0,
          "rhr_bpm": 52.0,
          "sources": {"hrv_ms": "healthkit", "rhr_bpm": "manual"},
          "healthkit": {
            "hrv_ms": {
              "value": 55.0,
              "sample_id": "sample-hrv",
              "sample_at": "2026-11-08T06:30:00+00:00",
              "source_name": "Apple Watch",
              "source_bundle_id": "com.apple.health",
              "source_class": "apple_watch",
              "source_model": "Watch6,18",
              "source_manufacturer": "Apple Inc.",
              "imported_at": "2026-11-08T07:00:00+00:00"
            }
          }
        }
        """#.utf8))
        XCTAssertEqual(payload.hrvMs, 55)
        XCTAssertEqual(payload.rhrBpm, 52)
        XCTAssertEqual(payload.sources?["hrv_ms"], "healthkit")
        XCTAssertEqual(payload.healthkit?["hrv_ms"]?.sourceClass, "apple_watch")
    }

    func testAppleWatchClassificationIsPositiveAndDeterministic() {
        XCTAssertEqual(
            HealthKitSourceClassifier.classify(
                manufacturer: "Apple Inc.", model: "Watch6,18"
            ), .appleWatch
        )
        XCTAssertEqual(
            HealthKitSourceClassifier.classify(
                manufacturer: "Apple", model: "Watch7,1"
            ), .appleWatch
        )
        XCTAssertEqual(
            HealthKitSourceClassifier.classify(
                manufacturer: "Apple Inc.", model: "iPhone15,2"
            ), .nonAppleWatch
        )
        XCTAssertEqual(
            HealthKitSourceClassifier.classify(
                manufacturer: "Garmin", model: "Forerunner"
            ), .nonAppleWatch
        )
        XCTAssertEqual(
            HealthKitSourceClassifier.classify(
                manufacturer: nil, model: nil
            ), .unknown
        )
        XCTAssertEqual(
            HealthKitSourceClassifier.classify(
                manufacturer: "Apple Inc.", model: nil
            ), .unknown
        )
        XCTAssertEqual(
            HealthKitSourceClassifier.classify(
                manufacturer: nil, model: "Watch6,18"
            ), .unknown
        )
    }

    func testAppleWatchWinsOnlyWhenPositivelyClassified() {
        let now = Date()
        let apple = observation(
            .hrvMs, 50, id: "apple", at: now.addingTimeInterval(-7_200),
            sourceClass: .appleWatch
        )
        let other = observation(
            .hrvMs, 60, id: "other", at: now.addingTimeInterval(-3_600),
            sourceClass: .nonAppleWatch
        )
        let selection = HealthKitReadinessSelection.make(
            hrvCandidates: [apple, other], rhrCandidates: [],
            serverDate: serverDate(now), now: now
        )
        XCTAssertEqual(selection.hrv?.sampleID, "apple")
        XCTAssertNil(selection.rhr)
        XCTAssertTrue(selection.staleFields.isEmpty)
    }

    func testNewestFallbackAndUnknownDoesNotBecomeAppleWatch() {
        let now = Date()
        let nonApple = observation(
            .hrvMs, 51, id: "non", at: now.addingTimeInterval(-7_200),
            sourceClass: .nonAppleWatch
        )
        let unknown = observation(
            .hrvMs, 62, id: "unknown", at: now.addingTimeInterval(-3_600),
            sourceClass: .unknown
        )
        let selection = HealthKitReadinessSelection.make(
            hrvCandidates: [nonApple, unknown], rhrCandidates: [],
            serverDate: serverDate(now), now: now
        )
        XCTAssertEqual(selection.hrv?.sampleID, "unknown")
        XCTAssertEqual(selection.hrv?.sourceClass, .unknown)
    }

    func testBodyweightSelectionUsesTheNewestSampleWithinThirtyDays() {
        let now = Date()
        let recent = observation(
            .bodyweightKg, 80.0, id: "weight-new", at: now.addingTimeInterval(-24 * 60 * 60),
            sourceClass: .appleWatch
        )
        let old = observation(
            .bodyweightKg, 82.0, id: "weight-old", at: now.addingTimeInterval(-10 * 24 * 60 * 60),
            sourceClass: .appleWatch
        )
        let selection = HealthKitReadinessSelection.make(
            hrvCandidates: [], rhrCandidates: [],
            bodyweightCandidates: [old, recent],
            serverDate: serverDate(now), now: now
        )
        XCTAssertEqual(selection.bodyweight?.sampleID, "weight-new")
        XCTAssertNil(selection.hrv)
        XCTAssertNil(selection.rhr)
        XCTAssertTrue(selection.staleFields.isEmpty)
    }

    func testPartialAndStaleMetricStatesAreIndependent() {
        let now = Date()
        let hrv = observation(
            .hrvMs, 55, id: "hrv", at: now, sourceClass: .appleWatch
        )
        let staleRhr = observation(
            .rhrBpm, 52, id: "rhr-stale",
            at: now.addingTimeInterval(-2 * 24 * 60 * 60),
            sourceClass: .appleWatch
        )
        let partial = HealthKitReadinessSelection.make(
            hrvCandidates: [hrv], rhrCandidates: [staleRhr],
            serverDate: serverDate(now), now: now
        )
        XCTAssertEqual(partial.status(for: .hrvMs), .eligible)
        XCTAssertEqual(partial.status(for: .rhrBpm), .stale)
        XCTAssertEqual(partial.status(for: .bodyweightKg), .missing)
        XCTAssertNotNil(partial.hrv)
        XCTAssertNil(partial.rhr)

        let rhr = observation(
            .rhrBpm, 52, id: "rhr", at: now, sourceClass: .appleWatch
        )
        let missingHrv = HealthKitReadinessSelection.make(
            hrvCandidates: [], rhrCandidates: [rhr],
            serverDate: serverDate(now), now: now
        )
        XCTAssertEqual(missingHrv.status(for: .hrvMs), .missing)
        XCTAssertEqual(missingHrv.status(for: .rhrBpm), .eligible)
        XCTAssertNil(missingHrv.hrv)
        XCTAssertNotNil(missingHrv.rhr)

        let allMissing = HealthKitReadinessSelection.make(
            hrvCandidates: [], rhrCandidates: [],
            serverDate: serverDate(now), now: now
        )
        XCTAssertEqual(allMissing.status(for: .hrvMs), .missing)
        XCTAssertEqual(allMissing.status(for: .rhrBpm), .missing)
        XCTAssertEqual(allMissing.status(for: .bodyweightKg), .missing)

        let allStale = HealthKitReadinessSelection.make(
            hrvCandidates: [observation(
                .hrvMs, 55, id: "stale-hrv",
                at: now.addingTimeInterval(-49 * 60 * 60),
                sourceClass: .appleWatch
            )],
            rhrCandidates: [staleRhr],
            serverDate: serverDate(now), now: now
        )
        XCTAssertEqual(allStale.status(for: .hrvMs), .stale)
        XCTAssertEqual(allStale.status(for: .rhrBpm), .stale)
        XCTAssertTrue(allStale.isEmpty)

        let both = HealthKitReadinessSelection.make(
            hrvCandidates: [hrv], rhrCandidates: [rhr],
            serverDate: serverDate(now), now: now
        )
        XCTAssertEqual(both.status(for: .hrvMs), .eligible)
        XCTAssertEqual(both.status(for: .rhrBpm), .eligible)
        XCTAssertFalse(both.isEmpty)
    }

    func testStaleSamplesRemainStaleAndAreNotImported() {
        let now = Date()
        let staleHrv = observation(
            .hrvMs, 55, id: "stale-hrv",
            at: now.addingTimeInterval(-49 * 60 * 60),
            sourceClass: .appleWatch
        )
        let staleRhr = observation(
            .rhrBpm, 52, id: "stale-rhr",
            at: now.addingTimeInterval(-2 * 24 * 60 * 60),
            sourceClass: .appleWatch
        )
        let selection = HealthKitReadinessSelection.make(
            hrvCandidates: [staleHrv], rhrCandidates: [staleRhr],
            serverDate: serverDate(now), now: now
        )
        XCTAssertTrue(selection.isEmpty)
        XCTAssertEqual(selection.staleFields, [.hrvMs, .rhrBpm])
    }

    func testDeterministicTieUsesSampleID() {
        let now = Date()
        let first = observation(
            .hrvMs, 55, id: "b", at: now, sourceClass: .nonAppleWatch
        )
        let second = observation(
            .hrvMs, 55, id: "a", at: now, sourceClass: .nonAppleWatch
        )
        let selection = HealthKitReadinessSelection.make(
            hrvCandidates: [first, second], rhrCandidates: [],
            serverDate: serverDate(now), now: now
        )
        XCTAssertEqual(selection.hrv?.sampleID, "a")
    }
}
