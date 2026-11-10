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
    ///
    /// Updates stop when iOS suspends the app, which it likely does once the timer paused playback in the
    /// background: a shake during the grace period probably needs the app in the foreground (check on a device).
    ///
    /// A motion manager has one accelerometer handler, so starting replaces another detector's updates. A detector
    /// stops the manager only while its own updates run.
    @MainActor
    public final class ShakeDetector: ShakeDetecting {
        /// The Android `SENSOR_DELAY_UI` rate.
        static let updateInterval: TimeInterval = 0.06
        /// Apple recommends one motion manager per app.
        private static let sharedMotionManager = CMMotionManager()

        private let motionManager: CMMotionManager
        private var recognizer: ShakeRecognizer?
        private var onShake: (@MainActor () -> Void)?
        private var isUpdating = false

        /// - Parameter motionManager: The app's motion manager, if it has one; otherwise a shared one.
        public init(motionManager: CMMotionManager? = nil) {
            self.motionManager = motionManager ?? Self.sharedMotionManager
        }

        isolated deinit {
            if isUpdating { motionManager.stopAccelerometerUpdates() }
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
                // Safe: the handler runs on `OperationQueue.main`, which executes on the main thread.
                MainActor.assumeIsolated { self?.receive(sample) }
            }
            isUpdating = true
        }

        public func stop() {
            if isUpdating { motionManager.stopAccelerometerUpdates() }
            isUpdating = false
            recognizer = nil
            onShake = nil
        }

        private func receive(_ sample: AccelerationSample) {
            guard recognizer?.process(sample) != nil else { return }
            onShake?()
        }
    }
#endif
