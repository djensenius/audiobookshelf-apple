import Foundation

/// A wait's time budget that a stall of the main actor doesn't use up. A busy CI runner can hold
/// the whole test process for over ten seconds; the work a condition waits on is then still queued
/// behind the waiter when it wakes, so a wall-clock deadline fails a passing test (#482). Each
/// check counts for at most ``maxStep``, so a stall costs one step while a hang still ends.
/// `now` is the time source, injectable so tests can simulate a stall without blocking the actor.
public struct WaitBudget {
    public typealias Now = () -> ContinuousClock.Instant

    public static let maxStep = Duration.milliseconds(100)
    private let now: Now
    private var remaining: Duration
    private var last: ContinuousClock.Instant

    public init(_ timeout: Duration, now: @escaping Now = { ContinuousClock.now }) {
        self.now = now
        remaining = timeout
        last = now()
    }

    /// Charges the time since the last check (at most ``maxStep``); whether any is left.
    public mutating func hasTimeLeft() -> Bool {
        let now = now()
        remaining -= min(now - last, Self.maxStep)
        last = now
        return remaining > .zero
    }
}
