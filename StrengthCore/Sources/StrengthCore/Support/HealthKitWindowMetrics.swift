import Foundation
import CryptoKit

/// Phone-side aggregation for the two HealthKit assessments that land in the periodic
/// `measurement` log: steps per day and sitting time.
///
/// Both are declared `aggregation: mean` in `config/measurements.v1.yaml`, so the phone sends one
/// value per window instead of a daily series. A daily series would make the stored trend a
/// mean-of-days that no one declared, and the append-only table has nowhere to put a revised
/// reading for a window it already holds.
///
/// Sitting is *derived*: HealthKit has no sitting type, only `appleStandTime`. The derivation is
/// carried in `method` so this number is never silently compared with a measured sitting time.
public enum HealthKitWindowMetric {
    public static let stepsKind = "steps_per_day"
    public static let sittingKind = "sitting_hours_per_day"

    /// Complete days per window. A week matches the catalogue note ("weekly or monthly average").
    public static let windowDays = 7

    public static let sittingDerivation = "24h - Apple Watch stand time"

    /// A completed calendar week, Monday to Sunday. The window excludes today on purpose: a
    /// partial day would make the same window produce a different mean every time it is re-synced.
    public struct Window: Equatable {
        /// First day of the window, at local midnight.
        public let start: Date
        /// Last day of the window, at local midnight.
        public let end: Date

        public init(start: Date, end: Date) {
            self.start = start
            self.end = end
        }

        public var days: Int {
            let seconds = end.timeIntervalSince(start)
            return Int((seconds / 86_400).rounded()) + 1
        }
    }

    /// The last completed calendar week: Monday to the most recent Sunday before today.
    ///
    /// A fixed weekly cadence matters because the window is the identity. A rolling "last seven
    /// days" would mint a new row every day, and a series of overlapping means averaged by
    /// `aggregation: mean` is not a trend anyone declared. Here a daily sync is a no-op until the
    /// week rolls over.
    public static func window(now: Date, calendar: Calendar = .current) -> Window {
        let today = calendar.startOfDay(for: now)
        // Calendar gives Sunday = 1. On any other day the most recent Sunday is `weekday - 1`
        // days back; on a Sunday the completed week is the one that ended seven days ago.
        let weekday = calendar.component(.weekday, from: today)
        let back = weekday == 1 ? windowDays : weekday - 1
        let end = calendar.date(byAdding: .day, value: -back, to: today) ?? today
        let start = calendar.date(byAdding: .day, value: -(windowDays - 1), to: end) ?? end
        return Window(start: start, end: end)
    }

    /// Stable identity for a window, so re-syncing the same week is a server-side no-op.
    ///
    /// A digest rather than the dates keeps the protocol's 16-byte key rule and keeps the phone
    /// from inventing an identity scheme the server has to learn.
    public static func key(kind: String, window: Window, calendar: Calendar = .current) -> String {
        let material = [kind, day(window.start, calendar: calendar), day(window.end, calendar: calendar)]
            .joined(separator: "|")
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    /// `yyyy-MM-dd` in the phone's own calendar, which is the day the server stores.
    public static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// One steps measurement for the window, or nil when HealthKit returned nothing at all.
    ///
    /// Days without a step count are left out rather than counted as zero: an unworn device is a
    /// missing day, and averaging it in would report a lower activity level than was measured.
    public static func stepsMetric(
        dailyTotals: [Double?],
        window: Window,
        calendar: Calendar = .current
    ) -> HealthKitActivityMetric? {
        let present = dailyTotals.compactMap { $0 }.filter { $0.isFinite && $0 >= 0 }
        guard let mean = mean(present) else { return nil }
        return HealthKitActivityMetric(
            key: key(kind: stepsKind, window: window, calendar: calendar),
            kind: stepsKind,
            measuredAt: day(window.end, calendar: calendar),
            value: mean,
            method: method(days: present.count, windowDays: windowDays)
        )
    }

    /// One sitting-time measurement for the window, or nil when no day has stand data.
    ///
    /// `dailyStandMinutes` holds HealthKit's `appleStandTime` per day. Stand time only exists
    /// while an Apple Watch is worn, so an iPhone-only athlete gets no row at all: missing, never
    /// zero.
    public static func sittingMetric(
        dailyStandMinutes: [Double?],
        window: Window,
        calendar: Calendar = .current
    ) -> HealthKitActivityMetric? {
        let hours = dailyStandMinutes.compactMap { minutes -> Double? in
            guard let minutes, minutes.isFinite, minutes >= 0 else { return nil }
            return min(max(24 - minutes / 60, 0), 24)
        }
        guard let mean = mean(hours) else { return nil }
        let base = method(days: hours.count, windowDays: windowDays)
        return HealthKitActivityMetric(
            key: key(kind: sittingKind, window: window, calendar: calendar),
            kind: sittingKind,
            measuredAt: day(window.end, calendar: calendar),
            value: mean,
            method: "\(base) (\(sittingDerivation))"
        )
    }

    /// The arithmetic mean, or nil for no values. Zero is a real value and is never dropped.
    public static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// `method` names the actual coverage: a two-day mean labelled "7-day" would overstate what
    /// was measured, and the method is the only place the protocol can travel.
    static func method(days: Int, windowDays: Int) -> String {
        days == windowDays ? "HealthKit: \(windowDays)-day mean" : "HealthKit: mean of \(days) days"
    }

    /// The daily statistics query used by the HealthKit adapter is one calendar day wide.
    public static func interval(window: Window, calendar: Calendar = .current) -> DateComponents {
        var components = DateComponents()
        components.day = 1
        return components
    }
}
