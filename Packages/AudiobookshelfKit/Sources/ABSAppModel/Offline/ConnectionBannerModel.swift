import ABSCore
import Foundation
import Observation

/// Runs ``ConnectionReachability`` for the connection banner (#76): feeds it the device's network
/// paths and the server's ping results, and performs its pings on an injected clock.
///
/// Call ``run()`` from a task that lives as long as the banner, such as the shell's `.task`; it
/// checks the server once, then follows the network until cancelled, which also cancels a
/// scheduled ping. ``retry()`` is the banner's retry button: it pings now and resets the backoff.
@MainActor
@Observable
public final class ConnectionBannerModel {
    /// Checks that the server answers, for example `GET /ping` (`AuthEndpoints.ping()`); throws
    /// when it doesn't. A `CancellationError` isn't counted as a failure.
    public typealias Ping = @Sendable () async throws -> Void

    /// The reducer, with the banner's ``state``.
    public private(set) var reachability = ConnectionReachability()

    @ObservationIgnored private let paths: @MainActor () -> AsyncStream<NetworkPath>
    @ObservationIgnored private let ping: Ping
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var pingTask: Task<Void, Never>?

    /// - Parameters:
    ///   - paths: the device's network paths, such as `NetworkMonitor.paths()`.
    ///   - ping: checks the server.
    ///   - clock: waits out the backoff between pings.
    ///   - now: the time a ping failed, for ``ConnectionBannerState/serverUnreachable(retryAt:)``.
    public init(
        paths: @escaping @MainActor () -> AsyncStream<NetworkPath>,
        ping: @escaping Ping,
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.paths = paths
        self.ping = ping
        self.clock = clock
        self.now = now
    }

    isolated deinit {
        pingTask?.cancel()
    }

    /// What the banner shows.
    public var state: ConnectionBannerState { reachability.state }

    /// Checks the server, then follows the network path until the calling task is cancelled.
    public func run() async {
        send(.retry)
        var epoch: UInt64?
        for await path in paths() {
            guard !Task.isCancelled else { break }
            let wasOffline = state == .offline(.noNetwork)
            send(.pathChanged(isOnline: path.isOnline))
            // Back online after an offline path the stream coalesced away: check the server again.
            if path.isOnline, !wasOffline, let epoch, epoch != path.onlineEpoch { send(.retry) }
            epoch = path.onlineEpoch
        }
        perform(.cancelPing)
    }

    /// Pings the server now and resets the backoff; does nothing without a network.
    public func retry() {
        send(.retry)
    }

    func send(_ event: ConnectionReachability.Event) {
        perform(reachability.reduce(event))
    }

    private func perform(_ effect: ConnectionReachability.Effect) {
        switch effect {
        case .none:
            break
        case .cancelPing:
            pingTask?.cancel()
            pingTask = nil
        case .ping(let attempt, let delay):
            pingTask?.cancel()
            pingTask = Task { [weak self, clock, ping, now] in
                if delay > .zero {
                    do { try await clock.sleep(for: delay) } catch { return }
                }
                guard !Task.isCancelled else { return }
                self?.send(.pingStarted(attempt: attempt))
                do {
                    try await ping()
                    self?.send(.pingSucceeded(attempt: attempt))
                } catch is CancellationError {
                    return
                } catch {
                    self?.send(.pingFailed(attempt: attempt, at: now()))
                }
            }
        }
    }
}
