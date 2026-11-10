import Foundation
import Observation

/// Watches the device's network path and publishes it through Observation and
/// `AsyncStream`s. Replaces the legacy Capacitor Network listener
/// (`store/index.js` `setupNetworkListener`).
///
/// ``path`` is `nil` until the source reports the first path. Each ``paths()`` stream
/// yields the current path (when known) and then every change; equal consecutive paths
/// are dropped. Streams keep only the newest unread path. All streams finish when the
/// monitor stops, its source ends, or it is deallocated.
@MainActor
@Observable
public final class NetworkMonitor {
    /// The latest path, or `nil` before the source reports one.
    public private(set) var path: NetworkPath?

    /// Whether the monitor is reading from its source.
    public private(set) var isRunning = false

    @ObservationIgnored private let source: any NetworkPathSource
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var subscribers: [UUID: AsyncStream<NetworkPath>.Continuation] = [:]

    public init(source: any NetworkPathSource = SystemNetworkPathSource()) {
        self.source = source
    }

    isolated deinit {
        task?.cancel()
        finishSubscribers()
    }

    /// Whether the device is online. `true` while the path is unknown, so callers don't
    /// block requests before the first update.
    public var isOnline: Bool { path?.isOnline ?? true }

    /// Starts reading from the source. Does nothing if already running.
    public func start() {
        guard task == nil else { return }
        isRunning = true
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

    /// Stops reading from the source and finishes every ``paths()`` stream. The last path
    /// is kept. The monitor can be started again.
    public func stop() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        isRunning = false
        finishSubscribers()
    }

    /// Returns a stream of paths for one subscriber.
    public func paths() -> AsyncStream<NetworkPath> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: NetworkPath.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.subscribers[id] = nil }
        }
        if let path {
            continuation.yield(path)
        }
        return stream
    }

    /// The number of live ``paths()`` streams. For tests.
    var subscriberCount: Int { subscribers.count }

    private func receive(_ newPath: NetworkPath) {
        guard newPath != path else { return }
        path = newPath
        for continuation in subscribers.values {
            continuation.yield(newPath)
        }
    }

    private func sourceDidFinish() {
        guard task != nil else { return }
        task = nil
        isRunning = false
        finishSubscribers()
    }

    private func finishSubscribers() {
        let continuations = subscribers.values
        subscribers.removeAll()
        for continuation in continuations {
            continuation.finish()
        }
    }
}
