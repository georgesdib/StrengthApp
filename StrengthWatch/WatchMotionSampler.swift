import CoreMotion
import Foundation
import StrengthCore

/// Thin CoreMotion wrapper: the only place that knows the sensor exists.
///
/// Batching lives here so the coordinator is not woken 100 times a second. All state is confined
/// to one serial queue; `stop` drains it before returning.
final class WatchMotionSampler {
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "watch.motion.sampler"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private var pending: [MotionSample] = []
    private var deliver: (([MotionSample]) -> Void)?
    private let batchSize = 20
    /// Latest raw readings, paired with each device-motion sample. Both streams run at the same
    /// interval, so the pairing error is at most one sample period.
    private var latestAccelerometer: CMAcceleration?
    private var latestGyro: CMRotationRate?

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    /// Starts device motion at the highest rate the hardware offers. Returns false when the
    /// sensor is unavailable, so the caller records nothing rather than an empty set.
    @discardableResult
    func start(rateHz: Double = 100, onBatch: @escaping ([MotionSample]) -> Void) -> Bool {
        stop()
        guard manager.isDeviceMotionAvailable else { return false }
        queue.addOperation { [weak self] in
            self?.pending = []
            self?.deliver = onBatch
        }
        manager.deviceMotionUpdateInterval = 1.0 / rateHz
        manager.accelerometerUpdateInterval = 1.0 / rateHz
        manager.gyroUpdateInterval = 1.0 / rateHz
        manager.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
            self?.latestAccelerometer = data?.acceleration
        }
        manager.startGyroUpdates(to: queue) { [weak self] data, _ in
            self?.latestGyro = data?.rotationRate
        }
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) {
            [weak self] motion, _ in
            guard let self, let motion else { return }
            let raw = self.latestAccelerometer
            let rawGyro = self.latestGyro
            self.pending.append(
                MotionSample(
                    t: motion.timestamp,
                    ax: motion.userAcceleration.x,
                    ay: motion.userAcceleration.y,
                    az: motion.userAcceleration.z,
                    rx: motion.rotationRate.x,
                    ry: motion.rotationRate.y,
                    rz: motion.rotationRate.z,
                    gx: motion.gravity.x,
                    gy: motion.gravity.y,
                    gz: motion.gravity.z,
                    rax: raw?.x, ray: raw?.y, raz: raw?.z,
                    rgx: rawGyro?.x, rgy: rawGyro?.y, rgz: rawGyro?.z
                )
            )
            if self.pending.count >= self.batchSize {
                self.flush()
            }
        }
        return true
    }

    func stop() {
        guard manager.isDeviceMotionActive else { return }
        manager.stopDeviceMotionUpdates()
        manager.stopAccelerometerUpdates()
        manager.stopGyroUpdates()
        queue.addOperation { [weak self] in
            self?.flush()
            self?.deliver = nil
        }
        queue.waitUntilAllOperationsAreFinished()
    }

    private func flush() {
        guard !pending.isEmpty, let deliver else { return }
        let batch = pending
        pending = []
        deliver(batch)
    }
}
