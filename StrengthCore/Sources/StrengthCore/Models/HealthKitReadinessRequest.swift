import Foundation

public struct HealthKitReadinessRequest: Encodable, Equatable {
    public let date: String
    public let samples: [HealthKitReadinessSample]

    public init(date: String, samples: [HealthKitReadinessSample]) {
        self.date = date
        self.samples = samples
    }
}

public struct HealthKitReadinessSample: Encodable, Equatable {
    public let field: String
    public let value: Double
    public let sampleId: String
    public let sampleAt: String
    public let sourceName: String
    public let sourceBundleId: String?
    public let sourceClass: String
    public let sourceModel: String?
    public let sourceManufacturer: String?

    public init(
        field: String,
        value: Double,
        sampleId: String,
        sampleAt: String,
        sourceName: String,
        sourceBundleId: String?,
        sourceClass: String,
        sourceModel: String?,
        sourceManufacturer: String?
    ) {
        self.field = field
        self.value = value
        self.sampleId = sampleId
        self.sampleAt = sampleAt
        self.sourceName = sourceName
        self.sourceBundleId = sourceBundleId
        self.sourceClass = sourceClass
        self.sourceModel = sourceModel
        self.sourceManufacturer = sourceManufacturer
    }
}
