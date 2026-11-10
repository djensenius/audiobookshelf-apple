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

    public init(timeout: Duration = .seconds(3), clock: any Clock<Duration> = ContinuousClock()) {
        self.timeout = timeout
        self.clock = clock
    }

    public func isDenied(host: String, port: Int) async -> Bool {
        guard let port = UInt16(exactly: port).flatMap(NWEndpoint.Port.init(rawValue:)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let verdicts = AsyncStream<Bool>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .waiting, .failed:
                    continuation.yield(connection.currentPath?.unsatisfiedReason == .localNetworkDenied)
                    continuation.finish()
                case .ready, .cancelled:
                    continuation.yield(false)
                    continuation.finish()
                default:
                    break
                }
            }
        }
        connection.start(queue: DispatchQueue(label: "org.davidjensenius.Audiobookshelf.LocalNetworkAccess"))
        defer { connection.cancel() }

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
}
