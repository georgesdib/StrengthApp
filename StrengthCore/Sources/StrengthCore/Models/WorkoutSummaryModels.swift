import Foundation

/// AFC-2i: the completed-workout summary envelope returned by the iOS facade. Every value here
/// is displayed from the server payload; the client never derives a ratio or judgement.
public struct WorkoutSummaryEnvelope: Decodable {
    public let summary: WorkoutSummary

    public init(summary: WorkoutSummary) {
        self.summary = summary
    }
}

public struct WorkoutSummary: Decodable {
    public let workoutId: String?
    public let sessionId: String?
    public let forDate: String?
    public let sessionType: String?
    public let status: String?
    public let adherence: WorkoutAdherence?
    public let vbt: WorkoutVBT?
    public let feedback: WorkoutFeedback?
    public let quality: WorkoutSummaryQuality?
    public let evidence: [WorkoutEvidence]?
}

public struct WorkoutAdherence: Decodable {
    public let version: String?
    public let status: String
    public let reason: String?
    public let original: AdherenceView?
    public let finalPlan: AdherenceView?
    public let changes: AdherenceChanges?
    public let quality: AdherenceQuality?

    enum CodingKeys: String, CodingKey {
        case version, status, reason, original, changes, quality
        case finalPlan = "finalPlan"
    }
}

public struct AdherenceView: Decodable {
    public let view: String?
    public let status: String
    public let prescribedSets: Int?
    public let performedSets: Int?
    public let matchedSets: Int?
    public let missingSets: Int?
    public let extraSets: Int?
    public let unattributablePlannedSets: Int?
    public let warmUpSetsExcluded: Int?
    public let setCompletion: AdherenceRatio?
    public let reps: AdherenceAttainment?
    public let load: AdherenceAttainment?
    public let rir: AdherenceAttainment?
    public let exercises: [AdherenceExercise]?
    public let quality: AdherenceViewQuality?
}

public struct AdherenceRatio: Decodable {
    public let numerator: Int?
    public let denominator: Int?
    public let ratio: Double?
}

public struct AdherenceAttainment: Decodable {
    public let attainment: AdherenceRatio?
    public let evaluatedSets: Int?
    public let withinTarget: Int?
    public let belowTarget: Int?
    public let aboveTarget: Int?
    public let atTarget: Int?
    public let unavailableSets: Int?
    public let meanAbsoluteDeviationKg: Double?
    public let meanDeviation: Double?
}

public struct AdherenceExercise: Decodable, Identifiable {
    public let exerciseId: String
    public let exerciseName: String?
    public let plannedSets: Int?
    public let performedSets: Int?
    public let matchedSets: Int?
    public let missingSets: Int?
    public let extraSets: Int?
    public let setCompletion: AdherenceRatio?
    public let reps: AdherenceAttainment?
    public let load: AdherenceAttainment?
    public let rir: AdherenceAttainment?
    public let status: String?
    public let attributable: Bool?
    public let limitations: [String]?

    public var id: String { exerciseId }
}

public struct AdherenceChanges: Decodable {
    public let swapped: [AdherenceChange]?
    public let added: [AdherenceChange]?
    public let removed: [AdherenceChange]?
    public let setCountChanged: [AdherenceChange]?
    public let targetsChanged: [AdherenceChange]?
}

public struct AdherenceChange: Decodable, Identifiable {
    public let planItemIndex: Int?
    public let exerciseId: String?
    public let fromExerciseId: String?
    public let toExerciseId: String?
    public let sets: Int?

    public var id: String {
        [String(planItemIndex ?? -1), exerciseId ?? "", fromExerciseId ?? "", toExerciseId ?? ""]
            .joined(separator: "-")
    }
}

public struct AdherenceQuality: Decodable {
    public let planModified: Bool?
    public let legacyPlanWithoutOrderIndex: Bool?
    public let warmUpSetsExcluded: Int?
    public let ambiguousStatusSets: Int?
    public let setsWithoutRir: Int?
    public let unmatchedSets: AdherenceQualityPair?
    public let ambiguousAttribution: AdherenceQualityPair?
    public let unattributablePlannedSets: AdherenceQualityPair?
    public let unavailableMetrics: [String]?
}

public struct AdherenceQualityPair: Decodable {
    public let original: Int?
    public let finalPlan: Int?
}

public struct AdherenceViewQuality: Decodable {
    public let unmatchedSets: Int?
    public let ambiguousAttribution: Int?
    public let mismatchedAttribution: Int?
    public let staleAttribution: Int?
    public let addedExerciseSets: Int?
    public let removedExerciseSets: Int?
    public let unattributableItems: Int?
    public let unavailableMetrics: [String]?
}

public struct WorkoutVBT: Decodable {
    public let status: String
    public let reason: String?
    public let exercises: [VBTExercise]?
    public let quality: VBTQuality?
}

public struct VBTExercise: Decodable, Identifiable {
    public let exerciseId: String
    public let sets: Int?
    public let comparableSets: Int?
    public let excludedSets: Int?
    public let meanSignedDeltaMps: Double?
    public let medianSignedDeltaMps: Double?
    public let meanAbsoluteErrorMps: Double?
    public let withinCalibrationBand: AdherenceRatio?
    public let aboveTarget: AdherenceRatio?
    public let belowTarget: AdherenceRatio?
    public let atTarget: AdherenceRatio?
    public let meanActualRir: Double?
    public let meanPrescribedRir: Double?

    public var id: String { exerciseId }
}

public struct VBTQuality: Decodable {
    public let loggedSets: Int?
    public let workingSets: Int?
    public let setsWithVelocity: Int?
    public let setsWithValidVelocity: Int?
    public let targetSets: Int?
    public let comparableSets: Int?
    public let excludedSets: Int?
    public let extraSets: Int?
    public let targetMetadata: [String: Int]?
    public let reasons: [String: Int]?
}

public struct WorkoutFeedback: Decodable {
    public let srpe: Double?
    public let durationMin: Double?
    public let durationSource: String?
    public let sessionLoadAu: Double?
    public let sessionLoadStatus: JSONValue?
    public let productivity: Int?
}

public struct WorkoutSummaryQuality: Decodable {
    public let flags: [WorkoutQualityFlag]?
    public let coverage: WorkoutQualityCoverage?
}

public struct WorkoutQualityFlag: Decodable, Identifiable {
    public let code: String
    public let detail: String?

    public var id: String { code }
}

public struct WorkoutQualityCoverage: Decodable {
    public let rir: Double?
    public let e1rm: Double?
}

public struct WorkoutEvidence: Decodable, Identifiable {
    public let evidenceId: String
    public let source: String
    public let sourceIds: [String]?
    public let window: WorkoutEvidenceWindow?
    public let unit: String?
    public let n: Int?
    public let comparability: String?
    public let gate: String?
    public let qualityFlags: [String]?
    public let limitations: [String]?

    public var id: String { evidenceId }
}

public struct WorkoutEvidenceWindow: Decodable {
    public let start: String?
    public let end: String?
}
