import Dispatch
import Network

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
            monitor.pathUpdateHandler = { path in
                continuation.yield(NetworkPath(path))
            }
            continuation.onTermination = { _ in
                monitor.cancel()
            }
            monitor.start(queue: DispatchQueue(label: "org.davidjensenius.Audiobookshelf.NetworkPathSource"))
        }
    }
}
