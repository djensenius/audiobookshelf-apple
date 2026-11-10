import Foundation
import Observation
import Synchronization

/// Watches the device's network path and publishes it through Observation and
/// `AsyncStream`s. Replaces the legacy Capacitor Network listener
/// (`store/index.js` `setupNetworkListener`).
///
/// ``path`` is `nil` until the source reports a path, and again after the source ends
/// or the monitor restarts. ``stop()`` keeps the last path.
/// Each ``paths()`` stream yields the current path (when known) and then every change;
/// equal consecutive paths are dropped and a stream keeps only the newest unread path.
/// Streams outlive ``stop()`` and ``start()``: a subscriber keeps receiving across
/// restarts, and its stream finishes only when the monitor is deallocated or the
/// subscriber cancels.
@MainActor
@Observable
public final class NetworkMonitor {
    /// The latest path, or `nil` before the source reports one.
    public private(set) var path: NetworkPath?

    /// Whether the monitor is reading from its source.
    public private(set) var isRunning = false

    @ObservationIgnored private let source: any NetworkPathSource
    @ObservationIgnored private let clock: any Clock<Duration>
    /// The task reading the source. Internal so tests can await a stopped run.
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    /// Guarded by a mutex so a cancelled subscriber is removed synchronously from its
    /// stream's termination handler, which runs on whatever thread cancels it.
    @ObservationIgnored private let subscribers = Subscribers()

    public init(
        source: any NetworkPathSource = SystemNetworkPathSource(), clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.source = source
        self.clock = clock
    }

    isolated deinit {
        task?.cancel()
        let continuations = subscribers.state.withLock { subscribers in
            defer { subscribers.removeAll() }
            return Array(subscribers.values)
        }
        for continuation in continuations {
            continuation.finish()
        }
    }

    /// Whether the device is online, for display. `true` while the path is unknown.
    public var isOnline: Bool { path?.isOnline ?? true }

    /// Starts reading from the source. Does nothing if already running. Clears ``path``,
    /// which may be stale after ``stop()``, so ``currentPath(timeout:)`` waits for this
    /// run's first report.
    public func start() {
        guard task == nil else { return }
        isRunning = true
        path = nil
        let stream = source.paths()
        task = Task { [weak self] in
            for await path in stream {
                guard let self, !Task.isCancelled else { return }
                self.receive(path)
            }
            // A cancelled task belongs to an earlier start(); stop() already cleaned up.
            guard !Task.isCancelled else { return }
            self?.sourceDidFinish()
        }
    }

    /// Stops reading from the source. The last path is kept and ``paths()`` streams stay
    /// open. The monitor can be started again.
    public func stop() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        isRunning = false
    }

    /// Returns a stream of paths for one subscriber.
    public func paths() -> AsyncStream<NetworkPath> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: NetworkPath.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuation.onTermination = { [subscribers] _ in
            _ = subscribers.state.withLock { $0.removeValue(forKey: id) }
        }
        subscribers.state.withLock { $0[id] = continuation }
        if let path {
            continuation.yield(path)
        }
        return stream
    }

    /// The current path, waiting up to `timeout` for the source's first report when it is
    /// still unknown (for example at a cold launch into CarPlay or auto-resume). Returns
    /// `nil` if no path arrives in time.
    public func currentPath(timeout: Duration = .milliseconds(500)) async -> NetworkPath? {
        if let path { return path }
        let updates = paths()
        let clock = clock
        let first = await withTaskGroup(of: NetworkPath?.self) { group in
            group.addTask { await updates.first { _ in true } }
            group.addTask {
                try? await clock.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
        return first ?? path
    }

    /// The number of live ``paths()`` streams. For tests.
    var subscriberCount: Int { subscribers.state.withLock { $0.count } }

    private func receive(_ newPath: NetworkPath) {
        guard newPath != path else { return }
        path = newPath
        for continuation in subscribers.state.withLock({ Array($0.values) }) {
            continuation.yield(newPath)
        }
    }

    private func sourceDidFinish() {
        guard task != nil else { return }
        task = nil
        isRunning = false
        path = nil
    }
}

/// A reference to the subscriber table, so termination handlers can capture it.
private final class Subscribers: Sendable {
    let state = Mutex<[UUID: AsyncStream<NetworkPath>.Continuation]>([:])
}
