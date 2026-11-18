import XCTest
@testable import StrengthApp
import StrengthCore

final class RecoveryHRVTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func reading(
        _ date: String = "2026-11-18",
        hour: Int,
        _ value: Double,
        source: String = "apple_watch",
        name: String = "Apple Watch"
    ) -> RecoveryHRVReading {
        let formatter = ISO8601DateFormatter()
        let date = formatter.date(from: "\(date)T\(String(format: "%02d", hour)):00:00Z")!
        return RecoveryHRVReading(
            sampledAt: date, value: value, sourceName: name, sourceClass: source
        )
    }

    func testNightTakesTheMedianOfTheMorningWindow() {
        let nights = RecoveryHRV.nights(
            from: [
                reading(hour: 2, 40),
                reading(hour: 6, 50),
                reading(hour: 9, 60),
            ],
            calendar: calendar
        )

        XCTAssertEqual(nights.count, 1)
        XCTAssertEqual(nights[0].date, "2026-11-18")
        XCTAssertEqual(nights[0].value, 50)
        XCTAssertEqual(nights[0].sampleCount, 3)
        XCTAssertEqual(nights[0].sourceClass, "apple_watch")
        XCTAssertEqual(nights[0].sampleAt, "2026-11-18T06:00:00Z")
    }

    func testDaytimeSamplesDoNotMakeANight() {
        let nights = RecoveryHRV.nights(
            from: [reading(hour: 14, 55), reading(hour: 21, 60)],
            calendar: calendar
        )

        XCTAssertTrue(nights.isEmpty, "a daytime reading is not a recovery value")
    }

    func testEachCalendarDayIsOneNight() {
        let nights = RecoveryHRV.nights(
            from: [
                reading("2026-11-17", hour: 23, 70),
                reading("2026-11-18", hour: 1, 40),
                reading("2026-11-18", hour: 7, 44),
            ],
            calendar: calendar
        )

        XCTAssertEqual(nights.map(\.date), ["2026-11-18"])
        XCTAssertEqual(nights[0].value, 44, "only the day's own window contributes")
    }

    func testSampleIDIsStableForTheSameValueAndChangesWithACorrection() {
        XCTAssertEqual(
            RecoveryHRV.sampleID(date: "2026-11-18", value: 48),
            RecoveryHRV.sampleID(date: "2026-11-18", value: 48)
        )
        XCTAssertNotEqual(
            RecoveryHRV.sampleID(date: "2026-11-18", value: 48),
            RecoveryHRV.sampleID(date: "2026-11-18", value: 49)
        )
    }

    func testAppleWatchSourceWinsForTheNight() {
        let nights = RecoveryHRV.nights(
            from: [
                reading(hour: 2, 40, source: "non_apple_watch", name: "Other"),
                reading(hour: 6, 50),
            ],
            calendar: calendar
        )

        XCTAssertEqual(nights[0].sourceClass, "apple_watch")
        XCTAssertEqual(nights[0].sourceName, "Apple Watch")
    }

    func testTimestampKeepsTheLocalOffset() {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = TimeZone(secondsFromGMT: 2 * 3600)!
        let date = ISO8601DateFormatter().date(from: "2026-11-18T05:00:00Z")!

        let nights = RecoveryHRV.nights(
            from: [RecoveryHRVReading(
                sampledAt: date, value: 50, sourceName: "Apple Watch", sourceClass: "apple_watch"
            )],
            calendar: local
        )

        XCTAssertEqual(nights[0].date, "2026-11-18")
        XCTAssertTrue(
            nights[0].sampleAt.hasSuffix("+02:00"),
            "the server checks sample_at against its own date: \(nights[0].sampleAt)"
        )
    }
}
