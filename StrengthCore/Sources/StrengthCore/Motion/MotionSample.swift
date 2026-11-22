import Foundation

/// One device-motion sample, flattened for a stable JSON shape.
///
/// Scalar fields rather than `SIMD3` because the recording is an interchange file that a
/// Python analysis step reads later: the column names matter more than the in-memory ergonomics.
public struct MotionSample: Codable, Equatable, Sendable {
    /// Monotonic seconds, taken from `CMDeviceMotion.timestamp`, never wall-clock.
    public let t: Double
    /// User acceleration in g, gravity removed.
    public let ax: Double
    public let ay: Double
    public let az: Double
    /// Rotation rate in radians per second.
    public let rx: Double
    public let ry: Double
    public let rz: Double
    /// Gravity direction in g, the only reliable "down" the wrist offers.
    public let gx: Double
    public let gy: Double
    public let gz: Double
    /// Raw accelerometer in g, **including gravity**, straight from the sensor.
    ///
    /// `ax`/`ay`/`az` come from CoreMotion's fused device motion, which is filtered to suppress
    /// drift — and that filter also suppresses the slow, large-amplitude movement of a squat,
    /// attenuating it several-fold. The raw channel is unfiltered; subtract gravity and project.
    /// Optional so recordings captured before this channel existed still decode.
    public let rax: Double?
    public let ray: Double?
    public let raz: Double?
    /// Raw rotation rate in radians per second, unfiltered. Optional for the same reason.
    public let rgx: Double?
    public let rgy: Double?
    public let rgz: Double?

    public init(
        t: Double,
        ax: Double, ay: Double, az: Double,
        rx: Double, ry: Double, rz: Double,
        gx: Double, gy: Double, gz: Double,
        rax: Double? = nil, ray: Double? = nil, raz: Double? = nil,
        rgx: Double? = nil, rgy: Double? = nil, rgz: Double? = nil
    ) {
        self.t = t
        self.ax = ax
        self.ay = ay
        self.az = az
        self.rx = rx
        self.ry = ry
        self.rz = rz
        self.gx = gx
        self.gy = gy
        self.gz = gz
        self.rax = rax
        self.ray = ray
        self.raz = raz
        self.rgx = rgx
        self.rgy = rgy
        self.rgz = rgz
    }
}

/// The axis phases are measured along. Supplied by the server on the plan item; the watch
/// never infers it, because wrist motion alone cannot tell a row from a squat.
public enum MotionAxis: String, Codable, Sendable, CaseIterable {
    case vertical
    case horizontal
}

/// Identity of the set a recording belongs to. This is the ordinal join key: the analysis
/// matches rep 1 to rep 1, so nothing here depends on a shared clock with the LPT.
public struct MotionCaptureContext: Codable, Equatable, Sendable {
    public let workoutId: String
    public let exerciseId: String
    public let planItemIndex: Int?
    public let setOrdinal: Int
    public let axis: MotionAxis?
    public let startedAt: Date

    public init(
        workoutId: String,
        exerciseId: String,
        planItemIndex: Int?,
        setOrdinal: Int,
        axis: MotionAxis?,
        startedAt: Date = Date()
    ) {
        self.workoutId = workoutId
        self.exerciseId = exerciseId
        self.planItemIndex = planItemIndex
        self.setOrdinal = setOrdinal
        self.axis = axis
        self.startedAt = startedAt
    }
}
