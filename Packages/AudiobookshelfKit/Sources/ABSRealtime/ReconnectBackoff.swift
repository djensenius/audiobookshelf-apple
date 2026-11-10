/// Exponential reconnect backoff with jitter, after socket.io-client's `backo2`: the uncapped
/// `initial * 2^attempt` is randomised by ±`jitter`, then clamped to `0...maximum` (15 s, as the
/// legacy app configured). Jitter applies before the cap, so late attempts stay at the maximum.
/// The exponent is limited to 16 only to avoid overflow.
struct ReconnectBackoff: Sendable {
    var initial: Duration = .seconds(1)
    var maximum: Duration = .seconds(15)
    var jitter: Double = 0.5

    /// `random` is in `0..<1`; 0.5 means no deviation.
    func delay(attempt: Int, random: Double) -> Duration {
        let exponent = min(max(attempt, 0), 16)
        let base = initial * (1 << exponent)
        let deviation = (min(max(random, 0), 1) * 2 - 1) * jitter
        return min(max(base * (1 + deviation), .zero), maximum)
    }
}
