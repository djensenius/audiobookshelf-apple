import Testing

@testable import ABSPlayback

/// Stands in for a motion manager or a detector: `MotionOwnership` only looks at identity.
private final class Identity: Sendable {}

/// `ShakeDetector` builds only on iOS, so these cover its bookkeeping: `claim` is a detector's `start`, and
/// `release` is its `stop()` or `deinit`, which stops the motion manager only when it returns `true`.
struct MotionOwnershipTests {
    private let manager = Identity()
    private let first = Identity()
    private let second = Identity()

    @Test func stoppingAnEarlierDetectorLeavesTheLaterOneRunning() {
        let ownership = MotionOwnership()
        ownership.claim(manager, for: first)
        ownership.claim(manager, for: second)

        // The first detector's updates were replaced when the second started.
        #expect(!ownership.release(manager, by: first))
        #expect(ownership.release(manager, by: second))
    }

    @Test func anEarlierDetectorStoppingAfterTheLaterOneDoesNothing() {
        let ownership = MotionOwnership()
        ownership.claim(manager, for: first)
        ownership.claim(manager, for: second)

        #expect(ownership.release(manager, by: second))
        #expect(!ownership.release(manager, by: first))
    }

    @Test func aStoppedDetectorStopsNothingMore() {
        let ownership = MotionOwnership()
        ownership.claim(manager, for: first)
        #expect(ownership.release(manager, by: first))
        // `deinit` after `stop()`.
        #expect(!ownership.release(manager, by: first))

        // The first detector is released after another one has started.
        ownership.claim(manager, for: second)
        #expect(!ownership.release(manager, by: first))
        #expect(ownership.release(manager, by: second))
    }

    @Test func startingAgainTakesTheManagerBack() {
        let ownership = MotionOwnership()
        ownership.claim(manager, for: first)
        ownership.claim(manager, for: second)
        ownership.claim(manager, for: first)

        #expect(!ownership.release(manager, by: second))
        #expect(ownership.release(manager, by: first))
    }

    @Test func aDetectorThatNeverStartedStopsNothing() {
        let ownership = MotionOwnership()
        #expect(!ownership.release(manager, by: first))

        ownership.claim(manager, for: second)
        #expect(!ownership.release(manager, by: first))
        #expect(ownership.release(manager, by: second))
    }

    @Test func eachManagerHasItsOwnOwner() {
        let otherManager = Identity()
        let ownership = MotionOwnership()
        ownership.claim(manager, for: first)
        ownership.claim(otherManager, for: second)

        #expect(!ownership.release(otherManager, by: first))
        #expect(!ownership.release(manager, by: second))
        #expect(ownership.release(manager, by: first))
        #expect(ownership.release(otherManager, by: second))
    }
}
