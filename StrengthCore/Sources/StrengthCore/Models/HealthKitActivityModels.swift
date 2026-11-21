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

/// Result of one of the two activity upload calls.
///
/// The server is deliberately per-item tolerant: a malformed metric or an immutable sample
/// conflict increments a counter instead of failing the whole batch. The client must therefore
/// read `rejected` and the nested metric `skipped` count; a 200 is not proof that every item
/// was stored.
public struct HealthKitActivityUploadResult: Decodable, Equatable {
    public let created: Int
    public let existing: Int
    /// Items the server declined to store. They need investigation, not blind re-submission.
    public let rejected: Int
    /// HealthKit keys the server rejected, when it can identify them. Empty from an older server;
    /// the caller must then hold the cursor instead of quarantining by key.
    public let rejectedKeys: [String]
    /// Present only on the samples call, which carries standalone metrics too.
    public let metrics: HealthKitActivityMetricUploadResult?

    private enum CodingKeys: String, CodingKey {
        case created, existing, rejected, rejectedKeys, metrics
    }

    public init(
        created: Int = 0,
        existing: Int = 0,
        rejected: Int = 0,
        rejectedKeys: [String] = [],
        metrics: HealthKitActivityMetricUploadResult? = nil
    ) {
        self.created = created
        self.existing = existing
        self.rejected = rejected
        self.rejectedKeys = rejectedKeys
        self.metrics = metrics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        created = try container.decodeIfPresent(Int.self, forKey: .created) ?? 0
        existing = try container.decodeIfPresent(Int.self, forKey: .existing) ?? 0
        // A metrics-only samples call omits rejected entirely.
        rejected = try container.decodeIfPresent(Int.self, forKey: .rejected) ?? 0
        rejectedKeys = try container.decodeIfPresent([String].self, forKey: .rejectedKeys) ?? []
        metrics = try container.decodeIfPresent(
            HealthKitActivityMetricUploadResult.self, forKey: .metrics
        )
    }

    public var skippedMetrics: Int { metrics?.skipped ?? 0 }
    public var isPartial: Bool { rejected > 0 || skippedMetrics > 0 }
}

public struct HealthKitActivityMetricUploadResult: Decodable, Equatable {
    public let written: Int
    public let skipped: Int

    public init(written: Int, skipped: Int) {
        self.written = written
        self.skipped = skipped
    }
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
