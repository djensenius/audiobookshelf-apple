import Dispatch
import Network

/// Tells whether the user has turned off local network access for the app (ADR 0002).
///
/// Call it only after a request to a host that may be local
/// (``HostScope/mayUseLocalNetwork(host:)``) failed to connect: the check opens a connection to
/// the host, and the system asks for permission on the first one.
public protocol LocalNetworkAccessChecking: Sendable {
    /// Whether a connection to `host` on `port` is refused because local network access is off.
    func isDenied(host: String, port: Int) async -> Bool
}

/// Opens a TCP connection to the host and reports a denial when the system leaves it waiting or
/// failed on a path whose unsatisfied reason is `localNetworkDenied` (TN3179). Anything else,
/// including no answer within `timeout`, is not a denial.
public struct SystemLocalNetworkAccess: LocalNetworkAccessChecking {
    private let timeout: Duration
    private let clock: any Clock<Duration>
    private let makeProbe: @Sendable (String, NWEndpoint.Port) -> any LocalNetworkProbe

    public init(timeout: Duration = .seconds(3), clock: any Clock<Duration> = ContinuousClock()) {
        self.init(timeout: timeout, clock: clock, makeProbe: ConnectionProbe.init(host:port:))
    }

    /// Watches the probe that `makeProbe` opens to the host and port instead of an `NWConnection`.
    init(
        timeout: Duration = .seconds(3), clock: any Clock<Duration> = ContinuousClock(),
        makeProbe: @escaping @Sendable (String, NWEndpoint.Port) -> any LocalNetworkProbe
    ) {
        self.timeout = timeout
        self.clock = clock
        self.makeProbe = makeProbe
    }

    public func isDenied(host: String, port: Int) async -> Bool {
        guard let port = UInt16(exactly: port).flatMap(NWEndpoint.Port.init(rawValue:)) else { return false }
        let probe = makeProbe(host, port)
        let verdicts = AsyncStream<Bool>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            probe.setStateHandler { state, unsatisfiedReason in
                guard let denied = Self.verdict(state, unsatisfiedReason: unsatisfiedReason) else { return }
                continuation.yield(denied)
                continuation.finish()
            }
        }
        probe.start()
        // The handler is cleared first, so the connection doesn't keep it and the stream after the check.
        defer {
            probe.setStateHandler(nil)
            probe.cancel()
        }

        let clock = clock
        let timeout = timeout
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await verdicts.first { _ in true } ?? false }
            group.addTask {
                try? await clock.sleep(for: timeout)
                return false
            }
            let denied = await group.next() ?? false
            group.cancelAll()
            return denied
        }
    }

    /// Whether `state` is a denial, or `nil` while the connection is still being set up.
    private static func verdict(_ state: NWConnection.State, unsatisfiedReason: NWPath.UnsatisfiedReason?) -> Bool? {
        switch state {
        case .waiting, .failed: unsatisfiedReason == .localNetworkDenied
        case .ready, .cancelled: false
        case .setup, .preparing: nil
        @unknown default: nil
        }
    }
}

/// The connection that ``SystemLocalNetworkAccess`` watches: an `NWConnection`, or a fake in tests.
protocol LocalNetworkProbe: Sendable {
    /// Sets, or with `nil` clears, the handler that receives each state and, if the connection has
    /// a path, the path's unsatisfied reason.
    func setStateHandler(_ handler: (@Sendable (NWConnection.State, NWPath.UnsatisfiedReason?) -> Void)?)
    func start()
    func cancel()
}

/// A TCP `NWConnection` to the host.
struct ConnectionProbe: LocalNetworkProbe {
    private let connection: NWConnection

    init(host: String, port: NWEndpoint.Port) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
    }

    func setStateHandler(_ handler: (@Sendable (NWConnection.State, NWPath.UnsatisfiedReason?) -> Void)?) {
        guard let handler else {
            connection.stateUpdateHandler = nil
            return
        }
        // Weak: the connection keeps its handler, which mustn't keep the connection.
        connection.stateUpdateHandler = { [weak connection = self.connection] state in
            handler(state, connection?.currentPath?.unsatisfiedReason)
        }
    }

    func start() {
        connection.start(queue: DispatchQueue(label: "org.davidjensenius.Audiobookshelf.LocalNetworkAccess"))
    }

    func cancel() {
        connection.cancel()
    }
}
