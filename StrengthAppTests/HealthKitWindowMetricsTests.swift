import XCTest

@testable import StrengthApp
import StrengthCore

final class HealthKitWindowMetricsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    func testWindowIsTheLastCompletedCalendarWeek() {
        // 2026-11-22 is a Sunday, so the finished week is the previous Monday to Sunday.
        let window = HealthKitWindowMetric.window(
            now: date("2026-11-22 09:30"), calendar: calendar
        )
        XCTAssertEqual(HealthKitWindowMetric.day(window.start, calendar: calendar), "2026-11-09")
        XCTAssertEqual(HealthKitWindowMetric.day(window.end, calendar: calendar), "2026-11-15")
        XCTAssertEqual(window.days, 7)
    }

    func testWindowStaysPutAllWeekAndRollsOnMonday() {
        let sunday = HealthKitWindowMetric.window(
            now: date("2026-11-22 23:00"), calendar: calendar
        )
        let saturday = HealthKitWindowMetric.window(
            now: date("2026-11-21 06:00"), calendar: calendar
        )
        XCTAssertEqual(sunday, saturday)

        let monday = HealthKitWindowMetric.window(
            now: date("2026-11-23 00:30"), calendar: calendar
        )
        XCTAssertEqual(HealthKitWindowMetric.day(monday.end, calendar: calendar), "2026-11-22")
        XCTAssertNotEqual(monday, sunday)
    }

    func testWindowKeyIsStableAcrossCallsAndDistinctPerWindow() {
        let window = HealthKitWindowMetric.window(
            now: date("2026-11-22 09:30"), calendar: calendar
        )
        let first = HealthKitWindowMetric.key(
            kind: HealthKitWindowMetric.stepsKind, window: window, calendar: calendar
        )
        let second = HealthKitWindowMetric.key(
            kind: HealthKitWindowMetric.stepsKind, window: window, calendar: calendar
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 32)
        XCTAssertTrue(first.allSatisfy { $0.isHexDigit })

        let sitting = HealthKitWindowMetric.key(
            kind: HealthKitWindowMetric.sittingKind, window: window, calendar: calendar
        )
        XCTAssertNotEqual(first, sitting)

        let later = HealthKitWindowMetric.window(
            now: date("2026-11-29 09:30"), calendar: calendar
        )
        XCTAssertNotEqual(
            first,
            HealthKitWindowMetric.key(
                kind: HealthKitWindowMetric.stepsKind, window: later, calendar: calendar
            )
        )
    }

    func testStepsAverageSkipsDaysWithoutData() throws {
        let window = HealthKitWindowMetric.window(
            now: date("2026-11-22 09:30"), calendar: calendar
        )
        let metric = try XCTUnwrap(HealthKitWindowMetric.stepsMetric(
            dailyTotals: [8000, nil, 10000, nil, nil, 6000, nil],
            window: window,
            calendar: calendar
        ))
        XCTAssertEqual(metric.value, 8000)
        XCTAssertEqual(metric.kind, "steps_per_day")
        XCTAssertEqual(metric.measuredAt, "2026-11-15")
        XCTAssertEqual(metric.method, "HealthKit: mean of 3 days")
    }

    func testStepsUsesTheSevenDayLabelOnlyWithFullCoverage() {
        let window = HealthKitWindowMetric.window(
            now: date("2026-11-22 09:30"), calendar: calendar
        )
        let metric = HealthKitWindowMetric.stepsMetric(
            dailyTotals: [1000, 1000, 1000, 1000, 1000, 1000, 1000],
            window: window,
            calendar: calendar
        )
        XCTAssertEqual(metric?.value, 1000)
        XCTAssertEqual(metric?.method, "HealthKit: 7-day mean")
    }

    func testStepsWithNoDataProduceNoMetric() {
        let window = HealthKitWindowMetric.window(
            now: date("2026-11-22 09:30"), calendar: calendar
        )
        XCTAssertNil(HealthKitWindowMetric.stepsMetric(
            dailyTotals: [nil, nil, nil], window: window, calendar: calendar
        ))
    }

    func testSittingIsTwentyFourHoursMinusStandTime() {
        let window = HealthKitWindowMetric.window(
            now: date("2026-11-22 09:30"), calendar: calendar
        )
        let metric = HealthKitWindowMetric.sittingMetric(
            dailyStandMinutes: [120, 120, 120, 120, 120, 120, 120],
            window: window,
            calendar: calendar
        )
        XCTAssertEqual(metric?.value ?? 0, 22, accuracy: 0.0001)
        XCTAssertEqual(metric?.kind, "sitting_hours_per_day")
        XCTAssertTrue(metric?.method.contains("24h - Apple Watch stand time") == true)
    }

    func testSittingIsClampedAndNilWithoutStandData() {
        let window = HealthKitWindowMetric.window(
            now: date("2026-11-22 09:30"), calendar: calendar
        )
        let allDay = HealthKitWindowMetric.sittingMetric(
            dailyStandMinutes: [1440], window: window, calendar: calendar
        )
        XCTAssertEqual(allDay?.value, 0)
        XCTAssertNil(HealthKitWindowMetric.sittingMetric(
            dailyStandMinutes: [nil, nil], window: window, calendar: calendar
        ))
    }
}
