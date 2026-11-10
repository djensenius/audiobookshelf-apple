import ABSCore
import Foundation
import Testing

@testable import ABSPlayback

/// A sample with total acceleration `g`, gravity included, along one axis.
private func sample(_ g: Double, at timestamp: TimeInterval, axis: Int = 2) -> AccelerationSample {
    AccelerationSample(
        x: axis == 0 ? g : 0, y: axis == 1 ? g : 0, z: axis == 2 ? g : 0, timestamp: timestamp)
}

/// Shaking along x at 4 Hz on top of gravity on z, peaking at `peak` g in total, sampled every 0.06 s (the
/// detector's update interval) for `duration` seconds.
private func shaking(peak: Double, duration: TimeInterval) -> [AccelerationSample] {
    let interval = 0.06
    let amplitude = (peak * peak - 1).squareRoot()
    return (0..<Int(duration / interval)).map { index in
        let time = Double(index) * interval
        return AccelerationSample(x: amplitude * sin(2 * .pi * 4 * time), y: 0, z: 1, timestamp: 100 + time)
    }
}

private func shakes(in samples: [AccelerationSample], sensitivity: ShakeSensitivity) -> [Int] {
    var recognizer = ShakeRecognizer(sensitivity: sensitivity)
    return samples.compactMap { recognizer.process($0) }
}

struct ShakeRecognizerTests {
    @Test func thresholdsMatchTheLegacySensitivities() {
        #expect(ShakeSensitivity.veryHigh.shakeThreshold == 1.1)
        #expect(ShakeSensitivity.high.shakeThreshold == 1.3)
        #expect(ShakeSensitivity.medium.shakeThreshold == 1.5)
        #expect(ShakeSensitivity.low.shakeThreshold == 2.0)
        #expect(ShakeSensitivity.veryLow.shakeThreshold == 2.7)
    }

    @Test(arguments: ShakeSensitivity.allCases)
    func shakeMustExceedTheThreshold(_ sensitivity: ShakeSensitivity) {
        let threshold = sensitivity.shakeThreshold
        var recognizer = ShakeRecognizer(sensitivity: sensitivity)
        #expect(recognizer.process(sample(threshold, at: 0)) == nil)
        #expect(recognizer.process(sample(threshold - 0.05, at: 1, axis: 0)) == nil)
        #expect(recognizer.process(sample(threshold + 0.05, at: 2, axis: 1)) == 1)
    }

    @Test(arguments: ShakeSensitivity.allCases)
    func restingDeviceNeverShakes(_ sensitivity: ShakeSensitivity) {
        let resting = (0..<200).map { sample(1, at: Double($0) * 0.06) }
        #expect(shakes(in: resting, sensitivity: sensitivity).isEmpty)
    }

    @Test func ignoresShakesWithinHalfASecond() {
        var recognizer = ShakeRecognizer(sensitivity: .medium)
        #expect(recognizer.process(sample(3, at: 10)) == 1)
        #expect(recognizer.process(sample(3, at: 10.4)) == nil)
        #expect(recognizer.process(sample(3, at: 10.5)) == 2)
    }

    @Test func countRestartsAfterThreeQuietSeconds() {
        var recognizer = ShakeRecognizer(sensitivity: .medium)
        #expect(recognizer.process(sample(3, at: 10)) == 1)
        #expect(recognizer.process(sample(3, at: 13)) == 2)
        #expect(recognizer.process(sample(3, at: 16.01)) == 1)
    }

    /// A gentle (1.4 g), firm (2.5 g) and hard (3 g) shake against each sensitivity.
    @Test(arguments: [
        (ShakeSensitivity.veryHigh, [true, true, true]),
        (.high, [true, true, true]),
        (.medium, [false, true, true]),
        (.low, [false, true, true]),
        (.veryLow, [false, false, true]),
    ])
    func syntheticShakes(_ sensitivity: ShakeSensitivity, detected: [Bool]) {
        for (peak, isDetected) in zip([1.4, 2.5, 3], detected) {
            let count = shakes(in: shaking(peak: peak, duration: 2), sensitivity: sensitivity).count
            #expect((count > 0) == isDetected, "\(peak) g at \(sensitivity)")
            #expect(count <= 4, "At most one shake per half second")
        }
    }
}
