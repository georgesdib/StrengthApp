import Foundation

/// One raw SDNN reading considered for a night's recovery value.
public struct RecoveryHRVReading: Equatable, Sendable {
    public let sampledAt: Date
    public let value: Double
    public let sourceName: String
    public let sourceClass: String

    public init(sampledAt: Date, value: Double, sourceName: String, sourceClass: String) {
        self.sampledAt = sampledAt
        self.value = value
        self.sourceName = sourceName
        self.sourceClass = sourceClass
    }
}

/// One night's recovery HRV, as sent to the server. The id is deterministic from the date and the
/// value, so a retry is a duplicate while a corrected value is a separate append-only observation
/// that supersedes the earlier one.
public struct RecoveryHRVSample: Codable, Equatable, Sendable {
    public let sampleID: String
    public let date: String
    public let value: Double
    public let sampleAt: String
    public let sourceName: String
    public let sourceClass: String
    public let sampleCount: Int

    public init(
        sampleID: String,
        date: String,
        value: Double,
        sampleAt: String,
        sourceName: String,
        sourceClass: String,
        sampleCount: Int
    ) {
        self.sampleID = sampleID
        self.date = date
        self.value = value
        self.sampleAt = sampleAt
        self.sourceName = sourceName
        self.sourceClass = sourceClass
        self.sampleCount = sampleCount
    }

    enum CodingKeys: String, CodingKey {
        case sampleID = "sample_id"
        case date
        case value
        case sampleAt = "sample_at"
        case sourceName = "source_name"
        case sourceClass = "source_class"
        case sampleCount = "sample_count"
    }
}

public struct RecoveryHRVRequest: Codable, Equatable, Sendable {
    public let samples: [RecoveryHRVSample]

    public init(samples: [RecoveryHRVSample]) {
        self.samples = samples
    }
}

public struct RecoveryHRVUploadResult: Codable, Equatable, Sendable {
    public let accepted: [String]
    public let duplicates: [String]

    public init(accepted: [String], duplicates: [String]) {
        self.accepted = accepted
        self.duplicates = duplicates
    }
}

/// Turns raw SDNN readings into one recovery value per night.
///
/// A night is the local calendar day's samples taken before 10:00. That is the window that holds
/// overnight and on-waking readings without admitting a daytime Breathe session; a day with no
/// sample in it has no recovery value and readiness omits HRV rather than falling back to the
/// newest reading. Sleep data is not read, so the window is fixed rather than sleep-derived.
public enum RecoveryHRV {
    public static let windowEndHour = 10

    public static func nights(
        from readings: [RecoveryHRVReading],
        calendar: Calendar = .current
    ) -> [RecoveryHRVSample] {
        var byDay: [String: [RecoveryHRVReading]] = [:]
        for reading in readings {
            guard let hour = calendar.dateComponents([.hour], from: reading.sampledAt).hour,
                  hour < windowEndHour else { continue }
            let key = dateString(reading.sampledAt, calendar: calendar)
            byDay[key, default: []].append(reading)
        }
        return byDay.keys.sorted().compactMap { day in
            guard let dayReadings = byDay[day], !dayReadings.isEmpty else { return nil }
            return sample(for: day, readings: dayReadings, calendar: calendar)
        }
    }

    private static func sample(
        for day: String,
        readings: [RecoveryHRVReading],
        calendar: Calendar
    ) -> RecoveryHRVSample {
        let ordered = readings.sorted {
            if $0.value != $1.value { return $0.value < $1.value }
            return $0.sampledAt < $1.sampledAt
        }
        // Upper median: deterministic for an even count and robust to one stray reading.
        let chosen = ordered[ordered.count / 2]
        let watch = ordered.first { $0.sourceClass == "apple_watch" }
        let source = watch ?? chosen
        return RecoveryHRVSample(
            sampleID: sampleID(date: day, value: chosen.value),
            date: day,
            value: chosen.value,
            sampleAt: timestamp(chosen.sampledAt, calendar: calendar),
            sourceName: source.sourceName,
            sourceClass: source.sourceClass,
            sampleCount: ordered.count
        )
    }

    public static func sampleID(date: String, value: Double) -> String {
        let tenths = Int((value * 10).rounded())
        return "recovery-\(date)-\(tenths)"
    }

    private static func dateString(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func timestamp(_ date: Date, calendar: Calendar) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
