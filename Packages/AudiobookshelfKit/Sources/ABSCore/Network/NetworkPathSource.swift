import Dispatch
import Network
import Synchronization

/// Produces network path updates. ``NetworkMonitor`` reads paths through this protocol so
/// tests can drive it without `NWPathMonitor`.
public protocol NetworkPathSource: Sendable {
    /// Returns a new stream that yields the current path first, then every change. The
    /// source stops monitoring when the stream's consumer is cancelled or the stream is
    /// dropped.
    func paths() -> AsyncStream<NetworkPath>
}

/// The system path source, backed by one `NWPathMonitor` per stream.
public struct SystemNetworkPathSource: NetworkPathSource {
    public init() {}

    public func paths() -> AsyncStream<NetworkPath> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let monitor = NWPathMonitor()
            let epochs = OnlineEpochCounter()
            monitor.pathUpdateHandler = { path in
                continuation.yield(epochs.stamp(NetworkPath(path)))
            }
            continuation.onTermination = { _ in
                monitor.cancel()
            }
            monitor.start(queue: DispatchQueue(label: "org.davidjensenius.Audiobookshelf.NetworkPathSource"))
        }
    }
}

/// Stamps each path of one stream with its ``NetworkPath/onlineEpoch``.
final class OnlineEpochCounter: Sendable {
    private let state = Mutex<(wasOnline: Bool?, epoch: UInt64)>((nil, 0))

    func stamp(_ path: NetworkPath) -> NetworkPath {
        var path = path
        path.onlineEpoch = state.withLock { state in
            if state.wasOnline == false, path.isOnline { state.epoch += 1 }
            state.wasOnline = path.isOnline
            return state.epoch
        }
        return path
    }
}
