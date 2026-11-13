import ABSCore
import Foundation
import Observation

/// Runs ``ConnectionReachability`` for the connection banner (#76): feeds it the device's network
/// paths and the server's ping results, and performs its pings on an injected clock.
///
/// Call ``run()`` from a task that lives as long as the banner, such as the shell's `.task`; it
/// checks the server once, then follows the network until cancelled, which also cancels a
/// scheduled or running ping. Only the latest `run()` acts: an older one still finishing stops
/// without touching the newer one's pings. ``retry()`` is the banner's retry button: it pings now
/// and resets the backoff.
@MainActor
@Observable
public final class ConnectionBannerModel {
    /// Checks that the server answers, for example `GET /ping` (`AuthEndpoints.ping()`); throws
    /// when it doesn't. A `CancellationError` isn't counted as a failure.
    public typealias Ping = @Sendable () async throws -> Void

    /// The reducer, with the banner's ``state``.
    public private(set) var reachability = ConnectionReachability()
    /// Called with each new ``state`` as it changes, such as ``ReconnectRestorer/observe(_:)``.
    @ObservationIgnored public var stateDidChange: (@MainActor (ConnectionBannerState) -> Void)?

    @ObservationIgnored private let paths: @MainActor () -> AsyncStream<NetworkPath>
    @ObservationIgnored private let ping: Ping
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var pingTask: Task<Void, Never>?
    /// Which ``run()`` is current; an older one stops following paths and leaves pings alone.
    @ObservationIgnored private var runGeneration: UInt64 = 0

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
    /// Any change of online path (another interface, or an `onlineEpoch` showing an offline path
    /// the stream coalesced away) checks the server again: the new route may not reach it.
    public func run() async {
        runGeneration &+= 1
        let generation = runGeneration
        send(.retry)
        var previous: NetworkPath?
        for await path in paths() {
            guard !Task.isCancelled, generation == runGeneration else { break }
            let wasOffline = state == .offline(.noNetwork)
            send(.pathChanged(isOnline: path.isOnline))
            if path.isOnline, !wasOffline, let previous, previous != path { send(.retry) }
            previous = path
        }
        if generation == runGeneration { perform(.cancelPing) }
    }

    /// Pings the server now and resets the backoff; does nothing without a network.
    public func retry() {
        send(.retry)
    }

    func send(_ event: ConnectionReachability.Event) {
        let previous = state
        let effect = reachability.reduce(event)
        if state != previous { stateDidChange?(state) }
        perform(effect)
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
                // A ping cancelled meanwhile (its run ended, or it was replaced) reports nothing,
                // even if it finished anyway: it must not change the state or schedule a retry.
                do {
                    try await ping()
                    guard !Task.isCancelled else { return }
                    self?.send(.pingSucceeded(attempt: attempt))
                } catch {
                    guard !Task.isCancelled, !(error is CancellationError) else { return }
                    self?.send(.pingFailed(attempt: attempt, at: now()))
                }
            }
        }
    }
}
