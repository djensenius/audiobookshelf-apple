import ABSCore
import Foundation

/// One accelerometer reading: acceleration in g, gravity included, so a device at rest reads about 1 g.
struct AccelerationSample: Sendable, Hashable {
    var x: Double
    var y: Double
    var z: Double
    /// Seconds on any monotonic clock (CoreMotion uses seconds since boot).
    var timestamp: TimeInterval

    var gForce: Double { (x * x + y * y + z * z).squareRoot() }
}

/// Recognizes shakes in accelerometer samples, ported from the Android `ShakeDetector`.
///
/// A sample whose total acceleration exceeds the sensitivity's threshold is a shake, unless it comes less than
/// ``slop`` seconds after the previous shake. The returned count restarts after ``countReset`` seconds without one.
struct ShakeRecognizer: Sendable {
    /// The Android `SHAKE_SLOP_TIME_MS`.
    static let slop: TimeInterval = 0.5
    /// The Android `SHAKE_COUNT_RESET_TIME_MS`.
    static let countReset: TimeInterval = 3

    let threshold: Double
    private var lastShake: TimeInterval?
    private var count = 0

    init(sensitivity: ShakeSensitivity) {
        threshold = sensitivity.shakeThreshold
    }

    /// The number of shakes in the current series if `sample` is a shake, otherwise `nil`.
    mutating func process(_ sample: AccelerationSample) -> Int? {
        guard sample.gForce > threshold else { return nil }
        if let lastShake {
            if sample.timestamp - lastShake < Self.slop { return nil }
            if sample.timestamp - lastShake > Self.countReset { count = 0 }
        }
        lastShake = sample.timestamp
        count += 1
        return count
    }
}

extension ShakeSensitivity {
    /// The g-force a shake must exceed, from the Android `DeviceSettings.getShakeThresholdGravity`.
    var shakeThreshold: Double {
        switch self {
        case .veryHigh: 1.1
        case .high: 1.3
        case .medium: 1.5
        case .low: 2.0
        case .veryLow: 2.7
        }
    }
}
