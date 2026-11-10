import ABSCore
import Foundation
import os

#if os(iOS)
    import CoreMotion
#endif

/// Reports device shakes to a ``SleepTimer``, which runs it only while shake to reset can do something.
@MainActor
public protocol ShakeDetecting: AnyObject {
    /// Starts reporting shakes at `sensitivity`, replacing any earlier handler.
    func start(sensitivity: ShakeSensitivity, onShake: @escaping @MainActor () -> Void)
    func stop()
}

#if os(iOS)
    private let logger = Logger(subsystem: "org.davidjensenius.Audiobookshelf", category: "ShakeDetector")

    /// Feeds CoreMotion accelerometer samples to a ``ShakeRecognizer``.
    @MainActor
    public final class ShakeDetector: ShakeDetecting {
        /// The Android `SENSOR_DELAY_UI` rate.
        static let updateInterval: TimeInterval = 0.06

        private let motionManager = CMMotionManager()
        private var recognizer: ShakeRecognizer?
        private var onShake: (@MainActor () -> Void)?

        public init() {}

        isolated deinit {
            motionManager.stopAccelerometerUpdates()
        }

        public func start(sensitivity: ShakeSensitivity, onShake: @escaping @MainActor () -> Void) {
            stop()
            guard motionManager.isAccelerometerAvailable else {
                logger.info("No accelerometer; shake to reset is unavailable")
                return
            }
            recognizer = ShakeRecognizer(sensitivity: sensitivity)
            self.onShake = onShake
            motionManager.accelerometerUpdateInterval = Self.updateInterval
            motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
                guard let data else { return }
                let acceleration = data.acceleration
                let sample = AccelerationSample(
                    x: acceleration.x, y: acceleration.y, z: acceleration.z, timestamp: data.timestamp)
                MainActor.assumeIsolated { self?.receive(sample) }
            }
        }

        public func stop() {
            motionManager.stopAccelerometerUpdates()
            recognizer = nil
            onShake = nil
        }

        private func receive(_ sample: AccelerationSample) {
            guard recognizer?.process(sample) != nil else { return }
            onShake?()
        }
    }
#endif
