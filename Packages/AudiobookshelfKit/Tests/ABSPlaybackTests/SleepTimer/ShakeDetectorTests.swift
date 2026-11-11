#if os(iOS)
    import CoreMotion
    import Testing

    @testable import ABSPlayback

    /// A motion manager that claims an accelerometer, which the simulator lacks, and counts the stops it is given.
    /// `@unchecked Sendable` is safe here: only the main-actor tests below touch `stops`.
    private final class StubMotionManager: CMMotionManager, @unchecked Sendable {
        private(set) var stops = 0

        override var isAccelerometerAvailable: Bool { true }

        override func startAccelerometerUpdates(
            to queue: OperationQueue, withHandler handler: @escaping CMAccelerometerHandler
        ) {}

        override func stopAccelerometerUpdates() {
            stops += 1
        }
    }

    /// `mise run test:kit:ios` runs this suite in PR CI and verifies all four methods in the result bundle.
    /// Host `test:kit` compiles it out; the package scheme (not the app scheme) runs it on an available iPhone.
    /// The stub motion manager needs neither a physical accelerometer nor an iPhone Duo.
    @MainActor
    struct ShakeDetectorTests {
        private let manager = StubMotionManager()

        @Test func aDetectorStopsItsOwnUpdates() {
            let detector = ShakeDetector(motionManager: manager)
            detector.start(sensitivity: .medium) {}
            #expect(manager.stops == 0)

            detector.stop()
            #expect(manager.stops == 1)
            detector.stop()
            #expect(manager.stops == 1)
        }

        @Test func stoppingAnEarlierDetectorLeavesTheLaterOneRunning() {
            let first = ShakeDetector(motionManager: manager)
            let second = ShakeDetector(motionManager: manager)
            first.start(sensitivity: .medium) {}
            second.start(sensitivity: .medium) {}

            first.stop()
            #expect(manager.stops == 0)

            second.stop()
            #expect(manager.stops == 1)
        }

        @Test func releasingAnEarlierDetectorLeavesTheLaterOneRunning() {
            var first: ShakeDetector? = ShakeDetector(motionManager: manager)
            let second = ShakeDetector(motionManager: manager)
            first?.start(sensitivity: .medium) {}
            second.start(sensitivity: .medium) {}

            first = nil
            #expect(manager.stops == 0)

            second.stop()
            #expect(manager.stops == 1)
        }

        @Test func releasingARunningDetectorStopsItsUpdates() {
            var detector: ShakeDetector? = ShakeDetector(motionManager: manager)
            detector?.start(sensitivity: .medium) {}

            detector = nil
            #expect(manager.stops == 1)
        }
    }
#endif
