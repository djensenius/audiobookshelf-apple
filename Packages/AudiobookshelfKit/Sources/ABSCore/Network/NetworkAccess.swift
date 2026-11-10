import Foundation

/// The URL loading system's network access flags for a ``CellularPolicy``, so the
/// transport enforces the same rules as ``NetworkPolicy``.
///
/// ``CellularPolicy/always`` and ``CellularPolicy/ask`` allow every network: with `ask`,
/// the user is asked before the task is created. ``CellularPolicy/never`` disallows
/// cellular and constrained (Low Data Mode) paths and, where expensive paths count as
/// cellular (macOS), expensive paths too. On iOS an expensive Wi-Fi path (a personal
/// hotspot) stays allowed, matching ``NetworkPolicy``.
///
/// A request's flags can only narrow its session's: a session that disallows a network
/// wins over a request that allows it.
public struct NetworkAccess: Sendable, Hashable {
    public var allowsCellularAccess: Bool
    public var allowsExpensiveNetworkAccess: Bool
    public var allowsConstrainedNetworkAccess: Bool

    public init(
        policy: CellularPolicy,
        treatsExpensiveAsCellular: Bool = NetworkPolicy.treatsExpensiveAsCellularByDefault
    ) {
        let allowsMetered = policy != .never
        allowsCellularAccess = allowsMetered
        allowsConstrainedNetworkAccess = allowsMetered
        allowsExpensiveNetworkAccess = allowsMetered || !treatsExpensiveAsCellular
    }
}

extension URLSessionConfiguration {
    /// Sets the network access flags from `access`.
    public func apply(_ access: NetworkAccess) {
        allowsCellularAccess = access.allowsCellularAccess
        allowsExpensiveNetworkAccess = access.allowsExpensiveNetworkAccess
        allowsConstrainedNetworkAccess = access.allowsConstrainedNetworkAccess
    }
}

extension URLRequest {
    /// Sets the network access flags from `access`.
    public mutating func apply(_ access: NetworkAccess) {
        allowsCellularAccess = access.allowsCellularAccess
        allowsExpensiveNetworkAccess = access.allowsExpensiveNetworkAccess
        allowsConstrainedNetworkAccess = access.allowsConstrainedNetworkAccess
    }
}
