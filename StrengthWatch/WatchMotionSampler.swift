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
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) {
            [weak self] motion, _ in
            guard let self, let motion else { return }
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
                    gz: motion.gravity.z
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
