import Foundation

/// Payloads for the incremental HealthKit activity upload (C2).
///
/// Timestamps are pre-formatted ISO-8601 strings because the client's JSON encoder does not set a
/// date strategy; sending Dates would produce epoch doubles the server cannot parse.
public struct HealthKitActivityWorkout: Encodable, Equatable {
    public let key: String            // HealthKit UUID as hex
    public let activityType: String
    public let startedAt: String
    public let endedAt: String
    public let durationS: Int
    public let sourceName: String
    public let avgHeartRate: Int?
    public let maxHeartRate: Int?
    public let activeEnergyKj: Double?
    public let distanceM: Double?
    public let avgMets: Double?
    public let srpe: Double?
    public let timezone: String?

    public init(
        key: String, activityType: String, startedAt: String, endedAt: String, durationS: Int,
        sourceName: String, avgHeartRate: Int? = nil, maxHeartRate: Int? = nil,
        activeEnergyKj: Double? = nil, distanceM: Double? = nil, avgMets: Double? = nil,
        srpe: Double? = nil, timezone: String? = nil
    ) {
        self.key = key
        self.activityType = activityType
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationS = durationS
        self.sourceName = sourceName
        self.avgHeartRate = avgHeartRate
        self.maxHeartRate = maxHeartRate
        self.activeEnergyKj = activeEnergyKj
        self.distanceM = distanceM
        self.avgMets = avgMets
        self.srpe = srpe
        self.timezone = timezone
    }
}

public struct HealthKitActivitySample: Encodable, Equatable {
    public let key: String            // HealthKit sample UUID as hex
    public let workoutKey: String
    public let kind: String           // heart_rate
    public let sampledAt: String
    public let value: Double
    public let unit: String
    public let association: String    // workout | tail
    public let sourceName: String

    public init(
        key: String, workoutKey: String, kind: String, sampledAt: String, value: Double,
        unit: String, association: String, sourceName: String
    ) {
        self.key = key
        self.workoutKey = workoutKey
        self.kind = kind
        self.sampledAt = sampledAt
        self.value = value
        self.unit = unit
        self.association = association
        self.sourceName = sourceName
    }
}

public struct HealthKitActivityWorkoutsBody: Encodable {
    public let workouts: [HealthKitActivityWorkout]
    public init(workouts: [HealthKitActivityWorkout]) { self.workouts = workouts }
}

public struct HealthKitActivityMetric: Encodable, Equatable {
    public let key: String            // HealthKit UUID as hex
    public let kind: String           // vo2max
    public let measuredAt: String
    public let value: Double
    public let method: String

    public init(key: String, kind: String, measuredAt: String, value: Double, method: String) {
        self.key = key
        self.kind = kind
        self.measuredAt = measuredAt
        self.value = value
        self.method = method
    }
}

public struct HealthKitActivitySamplesBody: Encodable {
    public let samples: [HealthKitActivitySample]
    public let metrics: [HealthKitActivityMetric]
    public init(samples: [HealthKitActivitySample], metrics: [HealthKitActivityMetric] = []) {
        self.samples = samples
        self.metrics = metrics
    }
}

public struct HealthKitActivityUploadResult: Decodable, Equatable {
    public let created: Int
    public let existing: Int
}

public struct HealthKitActivityBatch {
    public let workouts: [HealthKitActivityWorkout]
    public let samples: [HealthKitActivitySample]
    public let metrics: [HealthKitActivityMetric]
    public init(
        workouts: [HealthKitActivityWorkout],
        samples: [HealthKitActivitySample],
        metrics: [HealthKitActivityMetric] = []
    ) {
        self.workouts = workouts
        self.samples = samples
        self.metrics = metrics
    }
    public var isEmpty: Bool { workouts.isEmpty && samples.isEmpty && metrics.isEmpty }
}

/// ISO-8601 with an explicit UTC offset, the only form the server accepts.
public enum HealthKitActivityFormat {
    public static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
