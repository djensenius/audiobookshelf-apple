/// Exponential reconnect backoff with jitter, after socket.io-client's `backo2`: `initial * 2^attempt`
/// randomised by ±`jitter`, capped at `maximum` (15 s, as the legacy app configured).
struct ReconnectBackoff: Sendable {
    var initial: Duration = .seconds(1)
    var maximum: Duration = .seconds(15)
    var jitter: Double = 0.5

    /// `random` is in `0..<1`; 0.5 means no deviation.
    func delay(attempt: Int, random: Double) -> Duration {
        let exponent = min(max(attempt, 0), 16)
        let base = min(initial * (1 << exponent), maximum)
        let deviation = (min(max(random, 0), 1) * 2 - 1) * jitter
        return min(max(base * (1 + deviation), .zero), maximum)
    }
}
