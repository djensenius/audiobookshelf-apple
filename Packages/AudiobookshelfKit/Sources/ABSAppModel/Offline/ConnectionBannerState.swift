import Foundation

/// What the connection banner shows (#76), after legacy `ConnectionIndicator.vue`.
public enum ConnectionBannerState: Sendable, Hashable {
    /// The network is up and the server answered, or hasn't failed yet.
    case online
    /// The device has no usable network.
    case offline(OfflineReason)
    /// The network is up but the server didn't answer. The next automatic check is at
    /// `retryAt`, or `nil` while a check is running.
    case serverUnreachable(retryAt: Date?)

    /// The localized key that explains a missing connection, or `nil` online.
    public var messageKey: String? {
        switch self {
        case .online: nil
        case .offline(let reason): reason.messageKey
        case .serverUnreachable: "MessageAudiobookshelfServerNotConnected"
        }
    }
}

/// Why the device is offline.
public enum OfflineReason: Sendable, Hashable {
    /// The system reports no usable network path.
    case noNetwork

    /// The localized key that explains it.
    public var messageKey: String {
        switch self {
        case .noNetwork: "MessageNoNetworkConnection"
        }
    }
}

/// The connection banner's reducer: network path changes and server ping results in,
/// ``ConnectionBannerState`` and the next ping out. Pure, so the transitions and the backoff are
/// tested without a clock or a server; ``ConnectionBannerModel`` performs its effects.
///
/// - No network: ``ConnectionBannerState/offline(_:)``, no pings, and a ping still running is
///   ignored when it finishes.
/// - The network coming back, and ``Event/retry``: ``ConnectionBannerState/online`` is assumed
///   (or, while unreachable, a check shown as running) and the server is pinged at once, with the
///   backoff reset.
/// - A failed ping: ``ConnectionBannerState/serverUnreachable(retryAt:)``, pinging again after
///   ``delay(afterFailures:)``: 5 seconds, doubling up to a minute.
/// - A ping that succeeds: ``ConnectionBannerState/online``, with the backoff reset.
/// - Every ping has an attempt number; a result for any attempt but the latest is stale and
///   ignored.
public struct ConnectionReachability: Sendable, Hashable {
    public enum Event: Sendable, Hashable {
        /// The device's network path changed (`NetworkPath.isOnline`).
        case pathChanged(isOnline: Bool)
        /// The user asked to try again, or a check is wanted now, such as at launch.
        case retry
        /// A scheduled ping started.
        case pingStarted(attempt: UInt64)
        case pingSucceeded(attempt: UInt64)
        /// A ping failed at `at`.
        case pingFailed(attempt: UInt64, at: Date)
    }

    public enum Effect: Sendable, Hashable {
        case none
        /// Cancel the scheduled or running ping.
        case cancelPing
        /// Replace any scheduled or running ping with `attempt`, after `delay`.
        case ping(attempt: UInt64, delay: Duration)
    }

    /// The first retry's delay after a failed ping.
    public static let initialDelay: Duration = .seconds(5)
    /// The longest delay between retries.
    public static let maximumDelay: Duration = .seconds(60)

    public private(set) var state: ConnectionBannerState = .online
    /// Consecutive failed pings since the last success, reset or network change.
    public private(set) var failures = 0
    /// The latest ping's attempt number.
    public private(set) var attempt: UInt64 = 0
    /// Whether the network path is usable; assumed until a path is reported, as `NetworkMonitor` does.
    private var isNetworkOnline = true

    public init() {}

    /// The wait before the next ping after `failures` consecutive failures (at least one).
    public static func delay(afterFailures failures: Int) -> Duration {
        let exponent = min(max(failures - 1, 0), 16)
        return min(initialDelay * (1 << exponent), maximumDelay)
    }

    /// Applies `event` and returns what to do next.
    public mutating func reduce(_ event: Event) -> Effect {
        switch event {
        case .pathChanged(let isOnline):
            guard isOnline != isNetworkOnline else { return .none }
            isNetworkOnline = isOnline
            failures = 0
            attempt += 1
            guard isOnline else {
                state = .offline(.noNetwork)
                return .cancelPing
            }
            state = .online
            return .ping(attempt: attempt, delay: .zero)
        case .retry:
            guard isNetworkOnline else { return .none }
            failures = 0
            attempt += 1
            if case .serverUnreachable = state { state = .serverUnreachable(retryAt: nil) }
            return .ping(attempt: attempt, delay: .zero)
        case .pingStarted(let started):
            guard started == attempt, case .serverUnreachable = state else { return .none }
            state = .serverUnreachable(retryAt: nil)
            return .none
        case .pingSucceeded(let succeeded):
            guard succeeded == attempt else { return .none }
            failures = 0
            state = .online
            return .none
        case .pingFailed(let failed, let date):
            guard failed == attempt else { return .none }
            failures += 1
            attempt += 1
            let delay = Self.delay(afterFailures: failures)
            let (seconds, attoseconds) = delay.components
            state = .serverUnreachable(retryAt: date.addingTimeInterval(Double(seconds) + Double(attoseconds) / 1e18))
            return .ping(attempt: attempt, delay: delay)
        }
    }
}
