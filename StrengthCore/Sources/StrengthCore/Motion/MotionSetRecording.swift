import Foundation

/// One captured set, ready to write to disk.
///
/// `methodVersion` names the derivation algorithm, not the app build. Raw samples are discarded
/// after the study window, so a version change is a step change in every derived number and the
/// analysis must never pool across versions.
public struct MotionSetRecording: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let methodVersion = "tempo/1"

    public let schema: Int
    public let methodVersion: String
    public let context: MotionCaptureContext
    public let endedAt: Date
    public let nominalRateHz: Double
    public let gap: MotionGapReport
    public let samples: [MotionSample]

    public init(
        schema: Int = MotionSetRecording.schemaVersion,
        methodVersion: String = MotionSetRecording.methodVersion,
        context: MotionCaptureContext,
        endedAt: Date,
        nominalRateHz: Double,
        gap: MotionGapReport,
        samples: [MotionSample]
    ) {
        self.schema = schema
        self.methodVersion = methodVersion
        self.context = context
        self.endedAt = endedAt
        self.nominalRateHz = nominalRateHz
        self.gap = gap
        self.samples = samples
    }

    public var durationSeconds: Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return max(0, last.t - first.t)
    }
}

/// Accumulates samples for one set.
///
/// Samples arrive on a CoreMotion queue while `finish` runs on the caller's actor, so the buffer
/// is locked rather than confined to one thread.
public final class MotionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [MotionSample] = []

    public let context: MotionCaptureContext
    public let nominalRateHz: Double

    public init(context: MotionCaptureContext, nominalRateHz: Double = 100) {
        self.context = context
        self.nominalRateHz = nominalRateHz
    }

    public var sampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }

    public func append(_ newSamples: [MotionSample]) {
        guard !newSamples.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        samples.append(contentsOf: newSamples)
    }

    public func finish(endedAt: Date = Date()) -> MotionSetRecording {
        lock.lock()
        let captured = samples
        samples = []
        lock.unlock()
        return MotionSetRecording(
            context: context,
            endedAt: endedAt,
            nominalRateHz: nominalRateHz,
            gap: MotionGapReport.measure(captured, nominalRateHz: nominalRateHz),
            samples: captured
        )
    }
}
