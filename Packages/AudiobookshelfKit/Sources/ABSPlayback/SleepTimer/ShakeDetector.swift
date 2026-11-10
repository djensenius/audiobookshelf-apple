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

/// Which detector owns each motion manager's accelerometer handler.
///
/// A motion manager has one handler, so the detector that started last owns the manager and only it may stop the
/// manager's updates: an earlier detector that stops or is released leaves the new owner running. Kept apart from
/// ``ShakeDetector`` so that it builds, and is tested, on every platform. Not thread safe; detectors use it on the
/// main actor.
final class MotionOwnership {
    private var owners: [ObjectIdentifier: ObjectIdentifier] = [:]

    /// Hands `manager` to `owner`, taking it over from any earlier owner (a detector's `start`).
    func claim(_ manager: AnyObject, for owner: AnyObject) {
        owners[ObjectIdentifier(manager)] = ObjectIdentifier(owner)
    }

    /// Ends `owner`'s hold on `manager` and returns whether it had one. Only an owner may stop the manager's updates
    /// (a detector's `stop()` and `deinit`).
    func release(_ manager: AnyObject, by owner: AnyObject) -> Bool {
        let key = ObjectIdentifier(manager)
        guard owners[key] == ObjectIdentifier(owner) else { return false }
        owners[key] = nil
        return true
    }
}

#if os(iOS)
    private let logger = Logger(subsystem: "org.davidjensenius.Audiobookshelf", category: "ShakeDetector")

    /// Feeds CoreMotion accelerometer samples to a ``ShakeRecognizer``.
    ///
    /// Updates stop when iOS suspends the app, which it likely does once the timer paused playback in the
    /// background: a shake during the grace period probably needs the app in the foreground (check on a device).
    ///
    /// A motion manager has one accelerometer handler, so starting takes the manager over from another detector and
    /// replaces its updates. A detector stops the manager only while its own updates run: one that was taken over
    /// leaves the new owner running when it stops or is released.
    @MainActor
    public final class ShakeDetector: ShakeDetecting {
        /// The Android `SENSOR_DELAY_UI` rate.
        static let updateInterval: TimeInterval = 0.06
        /// Apple recommends one motion manager per app.
        private static let sharedMotionManager = CMMotionManager()
        /// The detector whose updates run on each motion manager.
        private static let ownership = MotionOwnership()

        private let motionManager: CMMotionManager
        private var recognizer: ShakeRecognizer?
        private var onShake: (@MainActor () -> Void)?

        /// - Parameter motionManager: The app's motion manager, if it has one; otherwise a shared one.
        public init(motionManager: CMMotionManager? = nil) {
            self.motionManager = motionManager ?? Self.sharedMotionManager
        }

        isolated deinit {
            stopUpdates()
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
            Self.ownership.claim(motionManager, for: self)
        }

        public func stop() {
            stopUpdates()
            recognizer = nil
            onShake = nil
        }

        /// Stops the manager's updates unless another detector has taken the manager over since this one started.
        private func stopUpdates() {
            if Self.ownership.release(motionManager, by: self) { motionManager.stopAccelerometerUpdates() }
        }

        private func receive(_ sample: AccelerationSample) {
            guard recognizer?.process(sample) != nil else { return }
            onShake?()
        }
    }
#endif
