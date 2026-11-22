import Foundation

/// How complete a captured set is.
///
/// A recording with holes cannot be trusted to align rep boundaries with anything, so the gap
/// report travels with the file instead of being inferred later. `isHealthy` is the gate the
/// study applies before a set is admissible.
public struct MotionGapReport: Codable, Equatable, Sendable {
    public let expectedSamples: Int
    public let actualSamples: Int
    public let maxGapSeconds: Double
    /// Intervals longer than three nominal periods. One dropped frame is tolerated; a stall is not.
    public let gaps: Int
    public let droppedFraction: Double

    public var isHealthy: Bool {
        actualSamples > 0 && gaps == 0 && droppedFraction <= 0.02
    }

    public init(
        expectedSamples: Int,
        actualSamples: Int,
        maxGapSeconds: Double,
        gaps: Int,
        droppedFraction: Double
    ) {
        self.expectedSamples = expectedSamples
        self.actualSamples = actualSamples
        self.maxGapSeconds = maxGapSeconds
        self.gaps = gaps
        self.droppedFraction = droppedFraction
    }

    public static func measure(
        _ samples: [MotionSample], nominalRateHz: Double
    ) -> MotionGapReport {
        guard nominalRateHz > 0 else {
            return MotionGapReport(
                expectedSamples: samples.count, actualSamples: samples.count,
                maxGapSeconds: 0, gaps: 0, droppedFraction: 0
            )
        }
        guard let first = samples.first, let last = samples.last, samples.count > 1 else {
            return MotionGapReport(
                expectedSamples: samples.count == 0 ? 0 : 1,
                actualSamples: samples.count,
                maxGapSeconds: 0,
                gaps: 0,
                droppedFraction: samples.count == 0 ? 1 : 0
            )
        }
        let period = 1.0 / nominalRateHz
        let duration = max(0, last.t - first.t)
        let expected = max(1, Int((duration / period).rounded()) + 1)
        var longest: Double = 0
        var gaps = 0
        for index in 1..<samples.count {
            let delta = samples[index].t - samples[index - 1].t
            longest = max(longest, delta)
            if delta > period * 3 { gaps += 1 }
        }
        let dropped = max(0, 1 - Double(samples.count) / Double(expected))
        return MotionGapReport(
            expectedSamples: expected,
            actualSamples: samples.count,
            maxGapSeconds: (longest * 1000).rounded() / 1000,
            gaps: gaps,
            droppedFraction: (dropped * 10000).rounded() / 10000
        )
    }
}
