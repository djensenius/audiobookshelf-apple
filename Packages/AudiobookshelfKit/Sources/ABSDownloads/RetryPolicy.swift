import Foundation

/// When to retry a failed transfer: exponential backoff with equal jitter, capped, for a
/// limited number of retries.
public struct RetryPolicy: Sendable, Equatable {
    /// The longest delay before the first retry.
    public var baseDelay: Duration
    /// The longest delay before any retry.
    public var maxDelay: Duration
    /// How many times a part is retried before it fails for good.
    public var maxRetries: Int

    public init(baseDelay: Duration, maxDelay: Duration, maxRetries: Int) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxRetries = maxRetries
    }

    /// 2 s, 4 s, 8 s, 16 s, 32 s (each with jitter), then give up.
    public static let `default` = RetryPolicy(baseDelay: .seconds(2), maxDelay: .seconds(300), maxRetries: 5)

    /// The delay before retry number `retry` (1-based), or `nil` once the retries are used up.
    ///
    /// The ceiling doubles with each retry up to ``maxDelay``; the delay is half the ceiling
    /// plus `random` (in `0...1`) times the other half, so parts that failed together don't
    /// retry in lockstep.
    public func delay(beforeRetry retry: Int, random: Double) -> Duration? {
        guard retry >= 1, retry <= maxRetries else { return nil }
        let ceiling = min(maxDelay, baseDelay * (1 << min(retry - 1, 32)))
        return ceiling / 2 + (ceiling / 2) * min(max(random, 0), 1)
    }
}
